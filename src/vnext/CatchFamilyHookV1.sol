// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {SafeTransferLib} from "../SafeTransferLib.sol";
import {ICatchFamilyFeeLedgerV1} from "./interfaces/ICatchFamilyFeeLedgerV1.sol";

/// @title cAsset paired-asset fee hook
/// @notice Charges a fixed 3% Catch fee in underlying on both directions of the
///         canonical cAsset/underlying pool.
/// @dev The hook accepts empty hook data and grants no router or wallet an
///      emission right. Fees accrue as PoolManager underlying claims, are redeemed as
///      real underlying, and can be permissionlessly flushed to the immutable family
///      ledger. The native 1% pool fee remains separate Uniswap accounting.
contract CatchFamilyHookV1 is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeTransferLib for address;

    uint256 public constant HOOK_FEE_BPS = 300;
    uint256 public constant BPS = 10_000;
    uint24 public constant LP_FEE = 10_000; // Uniswap v4 fee units: 1.00%

    struct PoolInfo {
        bool registered;
        uint64 directFlushNonce;
    }

    IPoolManager public immutable poolManager;
    address public immutable underlying;
    address public immutable cAsset;
    address public immutable factory;
    ICatchFamilyFeeLedgerV1 public feeLedger;
    bytes32 public feeLedgerCodeHash;

    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => uint256) public directUnderlyingAccrued;

    event PoolRegistered(PoolId indexed poolId);
    event FeeLedgerBound(address indexed feeLedger);
    event FeeAccrued(PoolId indexed poolId, uint256 feeUnderlying);
    event FeeFlushed(PoolId indexed poolId, bytes32 indexed feeKey, uint256 feeUnderlying);

    error AlreadyBound();
    error CodeHashChanged();
    error HookMismatch();
    error InvalidFee();
    error InvalidPair();
    error NotFactory();
    error NotPoolManager();
    error NothingToFlush();
    error PartialFillNotSupported();
    error PoolAlreadyRegistered();
    error UnexpectedCallbackResult();
    error UnknownPool();
    error ZeroAddress();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address underlying_, address cAsset_, address factory_) {
        if (
            address(poolManager_) == address(0) || underlying_ == address(0) || cAsset_ == address(0)
                || factory_ == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        underlying = underlying_;
        cAsset = cAsset_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice One-time factory binding to the immutable fee ledger.
    function bindFeeLedger(address feeLedger_) external {
        if (msg.sender != factory) revert NotFactory();
        if (address(feeLedger) != address(0)) revert AlreadyBound();
        if (feeLedger_ == address(0) || feeLedger_.code.length == 0) revert ZeroAddress();
        feeLedger = ICatchFamilyFeeLedgerV1(feeLedger_);
        feeLedgerCodeHash = feeLedger_.codehash;
        underlying.safeApprove(feeLedger_, type(uint256).max);
        emit FeeLedgerBound(feeLedger_);
    }

    /// @notice Exact Uniswap v4 callback permissions encoded in this address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Factory-only registration of the single canonical cAsset/underlying pool.
    function registerPool(PoolKey calldata key) external {
        if (msg.sender != factory) revert NotFactory();
        if (address(key.hooks) != address(this)) revert HookMismatch();
        if (key.fee != LP_FEE) revert InvalidFee();
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (!((currency0 == underlying && currency1 == cAsset) || (currency0 == cAsset && currency1 == underlying))) {
            revert InvalidPair();
        }
        PoolId id = key.toId();
        if (poolInfo[id].registered) revert PoolAlreadyRegistered();
        poolInfo[id].registered = true;
        emit PoolRegistered(id);
    }

    /// @notice Permissionlessly routes aggregate Catch fees to the fixed ledger.
    function flushDirect(PoolId id) external returns (uint256 amount) {
        _checkLedger();
        PoolInfo storage info = poolInfo[id];
        if (!info.registered) revert UnknownPool();
        amount = directUnderlyingAccrued[id];
        if (amount == 0) revert NothingToFlush();
        directUnderlyingAccrued[id] = 0;
        _redeemUnderlyingClaim(amount);
        bytes32 feeKey =
            keccak256(abi.encodePacked("CATCH_FAMILY_V1_DIRECT", PoolId.unwrap(id), ++info.directFlushNonce));
        feeLedger.routeHookUnderlying(feeKey, amount);
        emit FeeFlushed(id, feeKey, amount);
    }

    /// @notice Takes the 3% underlying fee before swaps whose specified currency is underlying.
    /// @dev The PoolManager alone calls this. Router identity and hook data are
    ///      deliberately ignored, preserving ordinary v4 routing compatibility.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (!poolInfo[id].registered) revert UnknownPool();
        (Currency specified,) = _sortCurrencies(key, params);
        if (Currency.unwrap(specified) != underlying) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        bool exactIn = params.amountSpecified < 0;
        uint256 underlyingLeg = _abs(params.amountSpecified);
        uint256 fee = exactIn ? _feeOnGross(underlyingLeg) : _feeFromNet(underlyingLeg);
        _accrue(id, specified, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @notice Takes the 3% underlying fee after swaps whose unspecified currency is underlying.
    /// @dev Together with `beforeSwap`, this covers exact-input and exact-output
    ///      buys and sells while always denominating the Catch fee in underlying.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        if (!poolInfo[id].registered) revert UnknownPool();
        (Currency specified, Currency unspecified) = _sortCurrencies(key, params);
        if (Currency.unwrap(specified) == underlying) {
            // A before-swap specified-currency delta is calculated from the user's
            // requested underlying amount. If a price limit stops the pool early, v4 does
            // not scale that delta down with the actual fill. Reject the whole swap
            // so the caller cannot pay a full Catch fee for a partial (or zero) fill.
            bool exactIn = params.amountSpecified < 0;
            uint256 requestedUnderlying = _abs(params.amountSpecified);
            uint256 specifiedFee = exactIn ? _feeOnGross(requestedUnderlying) : _feeFromNet(requestedUnderlying);
            bool underlyingSpecifiedIs0 = exactIn == params.zeroForOne;
            int128 executedSpecified = underlyingSpecifiedIs0 ? delta.amount0() : delta.amount1();
            int256 expectedSpecified =
                exactIn ? -int256(requestedUnderlying - specifiedFee) : int256(requestedUnderlying + specifiedFee);
            if (int256(executedSpecified) != expectedSpecified) revert PartialFillNotSupported();
            return (IHooks.afterSwap.selector, int128(0));
        }
        if (Currency.unwrap(unspecified) != underlying) return (IHooks.afterSwap.selector, int128(0));

        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 swapAmount = specifiedTokenIs0 ? delta.amount1() : delta.amount0();
        uint256 underlyingLeg = _abs(int256(swapAmount));
        uint256 fee = swapAmount < 0 ? _feeFromNet(underlyingLeg) : _feeOnGross(underlyingLeg);
        _accrue(id, unspecified, fee);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    function _accrue(PoolId id, Currency underlyingCurrency, uint256 fee) private {
        if (fee == 0) return;
        // The trader settles later in this unlock. Mint an ERC-6909 claim now rather than
        // attempting to withdraw ERC-20 reserves that have not arrived yet.
        poolManager.mint(address(this), uint256(uint160(Currency.unwrap(underlyingCurrency))), fee);
        directUnderlyingAccrued[id] += fee;
        emit FeeAccrued(id, fee);
    }

    function _checkLedger() private view {
        if (address(feeLedger) == address(0) || address(feeLedger).codehash != feeLedgerCodeHash) {
            revert CodeHashChanged();
        }
    }

    function _redeemUnderlyingClaim(uint256 amount) private {
        bytes memory result = poolManager.unlock(abi.encode(amount));
        if (result.length != 0) revert UnexpectedCallbackResult();
    }

    /// @notice PoolManager callback that redeems accrued underlying claims before flush.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        uint256 id = uint256(uint160(underlying));
        poolManager.burn(address(this), id, amount);
        poolManager.take(Currency.wrap(underlying), address(this), amount);
        return bytes("");
    }

    function _sortCurrencies(PoolKey calldata key, SwapParams calldata params)
        private
        pure
        returns (Currency specified, Currency unspecified)
    {
        (specified, unspecified) = (params.zeroForOne == (params.amountSpecified < 0))
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);
    }

    function _feeOnGross(uint256 gross) private pure returns (uint256) {
        return _ceilDiv(gross * HOOK_FEE_BPS, BPS);
    }

    function _feeFromNet(uint256 net) private pure returns (uint256) {
        return _ceilDiv(net * HOOK_FEE_BPS, BPS - HOOK_FEE_BPS);
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _abs(int256 x) private pure returns (uint256) {
        if (x == type(int256).min) revert SafeCast.SafeCastOverflow();
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    // Permissions are off. PoolManager never calls these functions for this hook address.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}

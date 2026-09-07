// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {SafeTransferLib} from "../SafeTransferLib.sol";
import {ICatchAsset} from "../interfaces/ICatchAsset.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {ICatchFamilyFeeLedgerV1} from "./interfaces/ICatchFamilyFeeLedgerV1.sol";

/// @title cAsset permanent genesis-liquidity locker
/// @notice Permanent owner of the one-sided 100,000 cAsset genesis position.
/// @dev There is deliberately no principal-removal or arbitrary-transfer surface. Anyone can
///      collect native v4 fees, but their destinations and the 70/30 policies are immutable.
contract CatchFamilyLiquidityLockerV1 is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeTransferLib for address;

    uint256 public constant GENESIS_CASSET = 100_000 ether;
    uint256 public constant MAXIMUM_GENESIS_DUST = 1 gwei;

    enum Operation {
        INITIALIZE,
        COLLECT
    }

    struct CallbackData {
        Operation operation;
        int256 liquidityDelta;
    }

    IPoolManager public immutable poolManager;
    address public immutable underlying;
    address public immutable cAsset;
    address public immutable factory;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    bytes32 public immutable positionSalt;
    bytes32 public immutable poolId;
    ICatchFamilyFeeLedgerV1 public feeLedger;
    bytes32 public feeLedgerCodeHash;
    PoolKey private poolKey;

    uint128 public genesisLiquidity;
    uint256 public genesisCAssetDeposited;
    uint256 public genesisDustBurned;
    uint64 public collectionNonce;
    bool public initialized;
    uint256 private locked = 1;

    event GenesisLocked(
        uint128 liquidity,
        uint256 cAssetDeposited,
        uint256 dustBurned,
        int24 tickLower,
        int24 tickUpper,
        bytes32 positionSalt
    );
    event FeeLedgerBound(address indexed feeLedger);
    event FeesCollected(bytes32 indexed collectionId, uint256 underlyingAmount, uint256 cAssetAmount);

    error AlreadyInitialized();
    error AlreadyBound();
    error CodeHashChanged();
    error GenesisDeliveryMismatch();
    error InvalidLiquidity();
    error InvalidPool();
    error NotFactory();
    error NotPoolManager();
    error Reentrancy();
    error ZeroAddress();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        IPoolManager poolManager_,
        PoolKey memory poolKey_,
        address underlying_,
        address cAsset_,
        address factory_,
        int24 tickLower_,
        int24 tickUpper_,
        bytes32 positionSalt_
    ) {
        if (
            address(poolManager_) == address(0) || underlying_ == address(0) || cAsset_ == address(0)
                || factory_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (tickLower_ >= tickUpper_) revert InvalidPool();
        address token0 = Currency.unwrap(poolKey_.currency0);
        address token1 = Currency.unwrap(poolKey_.currency1);
        if (!((token0 == underlying_ && token1 == cAsset_) || (token0 == cAsset_ && token1 == underlying_))) {
            revert InvalidPool();
        }
        poolManager = poolManager_;
        poolKey = poolKey_;
        underlying = underlying_;
        cAsset = cAsset_;
        factory = factory_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        positionSalt = positionSalt_;
        poolId = PoolId.unwrap(poolKey_.toId());
    }

    /// @notice Permanently binds the ledger that receives collected native fees.
    function bindFeeLedger(address feeLedger_) external {
        if (msg.sender != factory) revert NotFactory();
        if (address(feeLedger) != address(0)) revert AlreadyBound();
        if (feeLedger_ == address(0) || feeLedger_.code.length == 0) revert ZeroAddress();
        feeLedger = ICatchFamilyFeeLedgerV1(feeLedger_);
        feeLedgerCodeHash = feeLedger_.codehash;
        underlying.safeApprove(feeLedger_, type(uint256).max);
        cAsset.safeApprove(feeLedger_, type(uint256).max);
        emit FeeLedgerBound(feeLedger_);
    }

    /// @notice Canonical immutable cAsset/underlying PoolKey owned by this locker.
    function getPoolKey() external view returns (PoolKey memory) {
        return poolKey;
    }

    /// @notice Factory-only one-time creation of the permanent genesis position.
    function lockGenesis(uint128 liquidity) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        if (liquidity == 0) revert InvalidLiquidity();
        if (IERC20Minimal(cAsset).balanceOf(address(this)) != GENESIS_CASSET) revert GenesisDeliveryMismatch();
        uint256 lockerUnderlyingBefore = IERC20Minimal(underlying).balanceOf(address(this));
        bytes memory result =
            poolManager.unlock(abi.encode(CallbackData(Operation.INITIALIZE, int256(uint256(liquidity)))));
        if (result.length != 0) revert GenesisDeliveryMismatch();
        uint256 dust = IERC20Minimal(cAsset).balanceOf(address(this));
        if (dust > MAXIMUM_GENESIS_DUST || IERC20Minimal(underlying).balanceOf(address(this)) != lockerUnderlyingBefore)
        {
            revert GenesisDeliveryMismatch();
        }
        if (dust != 0) ICatchAsset(cAsset).burn(dust);
        initialized = true;
        genesisLiquidity = liquidity;
        genesisCAssetDeposited = GENESIS_CASSET - dust;
        genesisDustBurned = dust;
        emit GenesisLocked(liquidity, GENESIS_CASSET - dust, dust, tickLower, tickUpper, positionSalt);
    }

    /// @notice Permissionlessly collect native pool fees and apply the immutable family ledger.
    function collectAndAccount() external nonReentrant returns (uint256 underlyingAmount, uint256 cAssetAmount) {
        if (!initialized) revert InvalidLiquidity();
        if (address(feeLedger).codehash != feeLedgerCodeHash) revert CodeHashChanged();
        bytes memory result = poolManager.unlock(abi.encode(CallbackData(Operation.COLLECT, int256(0))));
        (underlyingAmount, cAssetAmount) = abi.decode(result, (uint256, uint256));
        bytes32 collectionId = keccak256(
            abi.encodePacked("CATCH_FAMILY_V1_LP_COLLECTION", poolId, ++collectionNonce, underlyingAmount, cAssetAmount)
        );
        if (underlyingAmount != 0) {
            feeLedger.routeLpUnderlying(keccak256(abi.encode(collectionId, "underlying")), underlyingAmount);
        }
        if (cAssetAmount != 0) feeLedger.routeLpCAsset(keccak256(abi.encode(collectionId, "cAsset")), cAssetAmount);
        emit FeesCollected(collectionId, underlyingAmount, cAssetAmount);
    }

    /// @notice PoolManager-only callback used to add genesis liquidity or collect fees.
    /// @dev No operation value maps to negative liquidity after construction.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: data.liquidityDelta, salt: positionSalt
            }),
            bytes("")
        );

        if (data.operation == Operation.INITIALIZE) {
            if (feesAccrued != BalanceDeltaLibrary.ZERO_DELTA) revert GenesisDeliveryMismatch();
        } else if (callerDelta != feesAccrued) {
            // A zero-liquidity poke must return fees only; principal movement
            // would imply this callback is no longer a pure collection path.
            revert InvalidLiquidity();
        }

        int128 amount0 = callerDelta.amount0();
        int128 amount1 = callerDelta.amount1();
        if (data.operation == Operation.INITIALIZE) {
            _settleGenesis(amount0, amount1);
            return bytes("");
        }

        uint256 amount0Out = _takePositive(poolKey.currency0, amount0);
        uint256 amount1Out = _takePositive(poolKey.currency1, amount1);
        if (amount0 < 0 || amount1 < 0) revert InvalidLiquidity();
        bool underlyingIsCurrency0 = Currency.unwrap(poolKey.currency0) == underlying;
        return
            abi.encode(underlyingIsCurrency0 ? amount0Out : amount1Out, underlyingIsCurrency0 ? amount1Out : amount0Out);
    }

    function _settleGenesis(int128 amount0, int128 amount1) private {
        bool underlyingIsCurrency0 = Currency.unwrap(poolKey.currency0) == underlying;
        int128 underlyingDelta = underlyingIsCurrency0 ? amount0 : amount1;
        int128 cAssetDelta = underlyingIsCurrency0 ? amount1 : amount0;
        if (underlyingDelta != 0 || cAssetDelta >= 0) {
            revert GenesisDeliveryMismatch();
        }
        uint256 requiredCAsset = uint256(uint128(-cAssetDelta));
        if (requiredCAsset > GENESIS_CASSET || GENESIS_CASSET - requiredCAsset > MAXIMUM_GENESIS_DUST) {
            revert GenesisDeliveryMismatch();
        }
        poolManager.sync(Currency.wrap(cAsset));
        cAsset.safeTransfer(address(poolManager), requiredCAsset);
        if (poolManager.settle() != requiredCAsset) revert GenesisDeliveryMismatch();
    }

    function _takePositive(Currency currency, int128 delta) private returns (uint256 amount) {
        if (delta <= 0) return 0;
        amount = uint256(uint128(delta));
        poolManager.take(currency, address(this), amount);
    }
}

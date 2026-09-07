// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CatchAsset} from "../CatchAsset.sol";
import {CatchAssetEmissionVault} from "../CatchAssetEmissionVault.sol";
import {CatchAssetReserveVault} from "../CatchAssetReserveVault.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {CatchFamilyFeeLedgerV1} from "./CatchFamilyFeeLedgerV1.sol";
import {CatchFamilyHookV1} from "./CatchFamilyHookV1.sol";
import {CatchFamilyLiquidityLockerV1} from "./CatchFamilyLiquidityLockerV1.sol";
import {CatchFamilyReleaseControllerV1} from "./CatchFamilyReleaseControllerV1.sol";

/// @title Catch fixed-policy cAsset family factory V1
/// @notice Canonical discovery and atomic-launch origin for isolated Robinhood
///         cAsset families that share the frozen Catch V1 economic policy.
/// @dev The factory is deliberately immutable and non-upgradeable. Each call
///      creates a fresh token, release vault, reserve vault, hook, permanent
///      genesis position, fee ledger and release controller. No family shares
///      custody or accounting with another family. A later policy change must
///      use a new factory version rather than mutating this one.
contract CatchFamilyFactoryV1 {
    using PoolIdLibrary for PoolKey;

    uint256 public constant COMPONENT_COUNT = 7;
    uint256 private constant ASSET = 0;
    uint256 private constant RELEASE_VAULT = 1;
    uint256 private constant RESERVE_VAULT = 2;
    uint256 private constant HOOK = 3;
    uint256 private constant LOCKER = 4;
    uint256 private constant LEDGER = 5;
    uint256 private constant RELEASE_CONTROLLER = 6;

    uint24 public constant LP_FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    int24 public constant CANONICAL_RANGE_WIDTH = 127_400;
    uint160 private constant HOOK_PERMISSION_MASK = 0xCC;
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint256 private constant Q192 = 1 << 192;
    uint256 private constant BPS = 10_000;

    uint256 public constant TARGET_INITIAL_CASSET_USD_E18 = 0.03 ether;
    uint256 public constant INITIAL_PRICE_TOLERANCE_BPS = 110;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    bytes32 public constant POLICY_ID =
        keccak256("CATCH_FAMILY_V1_1M_900K_100K_64STEP_3PCT_1PCT_70_30_127400TICKS_003USD_110BPS");
    uint256 public constant FACTORY_VERSION = 1;

    struct LaunchConfig {
        address underlying;
        string name;
        string symbol;
        bytes32 launchSalt;
        bytes32 hookSalt;
        bytes32 positionSalt;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint128 genesisLiquidity;
        uint256 launchUnderlyingUsdE18;
        bytes32 expectedUnderlyingRuntimeHash;
        bytes32 dependencyHash;
    }

    struct Family {
        bytes32 familyId;
        address underlying;
        address cAsset;
        address releaseVault;
        address reserveVault;
        address hook;
        address liquidityLocker;
        address feeLedger;
        address releaseController;
        bytes32 poolId;
        bytes32 configHash;
        bytes32 underlyingRuntimeHash;
        bytes32 dependencyHash;
    }

    IPoolManager public immutable poolManager;
    address public immutable treasury;
    address public immutable governance;
    address public immutable safetyCouncil;
    bytes32 public immutable poolManagerCodeHash;
    address[COMPONENT_COUNT] public codeDepots;
    bytes32[COMPONENT_COUNT] public depotCodeHashes;

    mapping(bytes32 => Family) private families;
    mapping(address => bytes32) public familyIdForUnderlying;
    mapping(address => bytes32) public familyIdForCAsset;
    mapping(bytes32 => bytes32) public familyIdForSymbolHash;
    mapping(bytes32 => bool) public launchSaltUsed;
    bytes32[] private familyIds;
    uint256 private locked = 1;

    event FamilyLaunched(
        bytes32 indexed familyId,
        uint256 indexed familyIndex,
        address indexed underlying,
        address cAsset,
        address releaseVault,
        address reserveVault,
        address hook,
        address liquidityLocker,
        address feeLedger,
        address releaseController,
        bytes32 poolId,
        bytes32 configHash,
        bytes32 dependencyHash
    );

    error AddressAlreadyRegistered();
    error DependencyCodeChanged();
    error DeploymentFailed(uint256 component);
    error DepotCodeChanged(uint256 component);
    error DuplicateLaunchSalt();
    error DuplicateSymbol();
    error GenesisMismatch();
    error InvalidDependencyHash();
    error InvalidDepot(uint256 component);
    error InvalidHookAddress();
    error InvalidMetadata();
    error InvalidRange();
    error InvalidStartingPrice();
    error NotGovernance();
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
        address treasury_,
        address governance_,
        address safetyCouncil_,
        address[COMPONENT_COUNT] memory codeDepots_
    ) {
        if (
            address(poolManager_) == address(0) || treasury_ == address(0) || governance_ == address(0)
                || safetyCouncil_ == address(0)
        ) revert ZeroAddress();
        if (address(poolManager_).code.length == 0) revert ZeroAddress();
        poolManager = poolManager_;
        treasury = treasury_;
        governance = governance_;
        safetyCouncil = safetyCouncil_;
        poolManagerCodeHash = address(poolManager_).codehash;
        for (uint256 i; i < COMPONENT_COUNT; ++i) {
            address depot = codeDepots_[i];
            if (depot == address(0) || depot.code.length == 0) revert InvalidDepot(i);
            codeDepots[i] = depot;
            depotCodeHashes[i] = depot.codehash;
        }
    }

    /// @notice Atomically creates and registers one isolated Catch family.
    /// @dev Only metadata, the underlying identity and deterministic market
    ///      geometry vary. Economic constants and destinations are factory-wide.
    function launch(LaunchConfig calldata config) external nonReentrant returns (Family memory deployed) {
        if (msg.sender != governance) revert NotGovernance();
        if (address(poolManager).codehash != poolManagerCodeHash) revert DependencyCodeChanged();
        _validateLaunchIdentity(config);

        bytes32 familyId = computeFamilyId(config.underlying);
        bytes32 symbolHash = keccak256(bytes(config.symbol));
        if (familyIdForUnderlying[config.underlying] != bytes32(0)) revert AddressAlreadyRegistered();
        if (familyIdForSymbolHash[symbolHash] != bytes32(0)) revert DuplicateSymbol();
        if (launchSaltUsed[config.launchSalt]) revert DuplicateLaunchSalt();

        launchSaltUsed[config.launchSalt] = true;
        uint256 factoryUnderlyingBefore = IERC20Minimal(config.underlying).balanceOf(address(this));

        CatchAsset cAsset = CatchAsset(
            _deploy(
                ASSET,
                componentSalt(familyId, config.launchSalt, "ASSET"),
                abi.encode(config.name, config.symbol, address(this), address(this))
            )
        );
        CatchAssetEmissionVault releaseVault = CatchAssetEmissionVault(
            _deploy(
                RELEASE_VAULT,
                componentSalt(familyId, config.launchSalt, "RELEASE_VAULT"),
                abi.encode(address(cAsset), address(this))
            )
        );
        CatchAssetReserveVault reserveVault = CatchAssetReserveVault(
            _deploy(
                RESERVE_VAULT,
                componentSalt(familyId, config.launchSalt, "RESERVE_VAULT"),
                abi.encode(address(cAsset), address(releaseVault), config.underlying)
            )
        );
        CatchFamilyHookV1 hook = CatchFamilyHookV1(
            _deploy(HOOK, config.hookSalt, abi.encode(poolManager, config.underlying, address(cAsset), address(this)))
        );
        if (uint160(address(hook)) & ALL_HOOK_MASK != HOOK_PERMISSION_MASK) revert InvalidHookAddress();

        (Currency currency0, Currency currency1) = config.underlying < address(cAsset)
            ? (Currency.wrap(config.underlying), Currency.wrap(address(cAsset)))
            : (Currency.wrap(address(cAsset)), Currency.wrap(config.underlying));
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        bool cAssetIsCurrency0 = Currency.unwrap(currency0) == address(cAsset);
        _validateMarketGeometry(config, cAssetIsCurrency0);

        CatchFamilyLiquidityLockerV1 locker = CatchFamilyLiquidityLockerV1(
            _deploy(
                LOCKER,
                componentSalt(familyId, config.launchSalt, "LOCKER"),
                abi.encode(
                    poolManager,
                    key,
                    config.underlying,
                    address(cAsset),
                    address(this),
                    config.tickLower,
                    config.tickUpper,
                    config.positionSalt
                )
            )
        );
        CatchFamilyFeeLedgerV1 feeLedger = CatchFamilyFeeLedgerV1(
            _deploy(
                LEDGER,
                componentSalt(familyId, config.launchSalt, "LEDGER"),
                abi.encode(
                    config.underlying,
                    address(cAsset),
                    address(reserveVault),
                    treasury,
                    address(hook),
                    address(locker),
                    address(this)
                )
            )
        );
        CatchFamilyReleaseControllerV1 releaseController = CatchFamilyReleaseControllerV1(
            _deploy(
                RELEASE_CONTROLLER,
                componentSalt(familyId, config.launchSalt, "RELEASE_CONTROLLER"),
                abi.encode(
                    config.underlying,
                    address(cAsset),
                    address(releaseVault),
                    address(reserveVault),
                    address(feeLedger),
                    governance,
                    safetyCouncil,
                    config.launchUnderlyingUsdE18
                )
            )
        );

        hook.bindFeeLedger(address(feeLedger));
        locker.bindFeeLedger(address(feeLedger));
        feeLedger.bindReleaseController(address(releaseController));
        releaseVault.bindController(address(releaseController));
        cAsset.bindReserveVault(address(reserveVault));

        if (!cAsset.transfer(address(releaseVault), 900_000 ether)) revert GenesisMismatch();
        if (!cAsset.transfer(address(locker), 100_000 ether)) revert GenesisMismatch();
        hook.registerPool(key);
        int24 launchTick = cAssetIsCurrency0 ? config.tickLower : config.tickUpper;
        if (poolManager.initialize(key, config.sqrtPriceX96) != launchTick) revert GenesisMismatch();
        locker.lockGenesis(config.genesisLiquidity);
        uint256 genesisDeposited = locker.genesisCAssetDeposited();
        if (
            cAsset.balanceOf(address(this)) != 0 || cAsset.balanceOf(address(releaseVault)) != 900_000 ether
                || cAsset.balanceOf(address(locker)) != 0 || cAsset.totalSupply() != 900_000 ether + genesisDeposited
                || IERC20Minimal(config.underlying).balanceOf(address(this)) != factoryUnderlyingBefore
        ) revert GenesisMismatch();

        bytes32 configHash = _configHash(config, familyId);
        deployed = Family({
            familyId: familyId,
            underlying: config.underlying,
            cAsset: address(cAsset),
            releaseVault: address(releaseVault),
            reserveVault: address(reserveVault),
            hook: address(hook),
            liquidityLocker: address(locker),
            feeLedger: address(feeLedger),
            releaseController: address(releaseController),
            poolId: PoolId.unwrap(key.toId()),
            configHash: configHash,
            underlyingRuntimeHash: config.expectedUnderlyingRuntimeHash,
            dependencyHash: config.dependencyHash
        });
        families[familyId] = deployed;
        familyIdForUnderlying[config.underlying] = familyId;
        familyIdForCAsset[address(cAsset)] = familyId;
        familyIdForSymbolHash[symbolHash] = familyId;
        uint256 familyIndex = familyIds.length;
        familyIds.push(familyId);

        emit FamilyLaunched(
            familyId,
            familyIndex,
            config.underlying,
            address(cAsset),
            address(releaseVault),
            address(reserveVault),
            address(hook),
            address(locker),
            address(feeLedger),
            address(releaseController),
            deployed.poolId,
            configHash,
            config.dependencyHash
        );
    }

    function familyCount() external view returns (uint256) {
        return familyIds.length;
    }

    function familyIdAt(uint256 index) external view returns (bytes32) {
        return familyIds[index];
    }

    function getFamily(bytes32 familyId) external view returns (Family memory) {
        return families[familyId];
    }

    function computeFamilyId(address underlying) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), underlying));
    }

    /// @notice Canonical commitment used by launch records and indexers.
    function hashLaunchConfig(LaunchConfig calldata config) external view returns (bytes32) {
        return _configHash(config, computeFamilyId(config.underlying));
    }

    function componentSalt(bytes32 familyId, bytes32 launchSalt, string memory component)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(familyId, launchSalt, component));
    }

    /// @notice Returns the USD value implied by a proposed discrete launch boundary.
    function impliedCAssetUsdE18(uint160 sqrtPriceX96, bool cAssetIsCurrency0, uint256 underlyingUsdE18)
        public
        pure
        returns (uint256)
    {
        if (sqrtPriceX96 == 0 || underlyingUsdE18 == 0) revert InvalidStartingPrice();
        uint256 sqrt = uint256(sqrtPriceX96);
        uint256 currency1PerCurrency0E18 = FullMath.mulDiv(sqrt, sqrt * 1 ether, Q192);
        if (currency1PerCurrency0E18 == 0) revert InvalidStartingPrice();
        return cAssetIsCurrency0
            ? FullMath.mulDiv(currency1PerCurrency0E18, underlyingUsdE18, 1 ether)
            : FullMath.mulDiv(underlyingUsdE18, 1 ether, currency1PerCurrency0E18);
    }

    function _validateLaunchIdentity(LaunchConfig calldata config) private view {
        uint256 nameLength = bytes(config.name).length;
        uint256 symbolLength = bytes(config.symbol).length;
        if (config.underlying == address(0)) revert ZeroAddress();
        if (nameLength == 0 || nameLength > MAX_NAME_BYTES || symbolLength == 0 || symbolLength > MAX_SYMBOL_BYTES) {
            revert InvalidMetadata();
        }
        if (
            config.launchSalt == bytes32(0) || config.hookSalt == bytes32(0) || config.positionSalt == bytes32(0)
                || config.genesisLiquidity == 0 || config.launchUnderlyingUsdE18 == 0
        ) revert InvalidRange();
        if (config.dependencyHash == bytes32(0)) revert InvalidDependencyHash();
        if (
            config.underlying.code.length == 0 || config.expectedUnderlyingRuntimeHash == bytes32(0)
                || config.underlying.codehash != config.expectedUnderlyingRuntimeHash
        ) revert DependencyCodeChanged();
        if (IERC20Minimal(config.underlying).decimals() != 18) revert GenesisMismatch();
    }

    function _validateMarketGeometry(LaunchConfig calldata config, bool cAssetIsCurrency0) private pure {
        if (
            config.tickLower < TickMath.MIN_TICK || config.tickUpper > TickMath.MAX_TICK
                || config.tickLower >= config.tickUpper || config.tickLower % TICK_SPACING != 0
                || config.tickUpper % TICK_SPACING != 0
                || int256(config.tickUpper) - int256(config.tickLower) != int256(CANONICAL_RANGE_WIDTH)
        ) revert InvalidRange();
        int24 launchTick = cAssetIsCurrency0 ? config.tickLower : config.tickUpper;
        if (config.sqrtPriceX96 != TickMath.getSqrtPriceAtTick(launchTick)) revert InvalidRange();
        uint256 impliedPrice =
            impliedCAssetUsdE18(config.sqrtPriceX96, cAssetIsCurrency0, config.launchUnderlyingUsdE18);
        uint256 difference = impliedPrice > TARGET_INITIAL_CASSET_USD_E18
            ? impliedPrice - TARGET_INITIAL_CASSET_USD_E18
            : TARGET_INITIAL_CASSET_USD_E18 - impliedPrice;
        if (difference > TARGET_INITIAL_CASSET_USD_E18 * INITIAL_PRICE_TOLERANCE_BPS / BPS) {
            revert InvalidStartingPrice();
        }
    }

    function _configHash(LaunchConfig calldata config, bytes32 familyId) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                POLICY_ID,
                familyId,
                config.underlying,
                keccak256(bytes(config.name)),
                keccak256(bytes(config.symbol)),
                config.launchSalt,
                config.hookSalt,
                config.positionSalt,
                config.tickLower,
                config.tickUpper,
                config.sqrtPriceX96,
                config.genesisLiquidity,
                config.launchUnderlyingUsdE18,
                config.expectedUnderlyingRuntimeHash,
                config.dependencyHash
            )
        );
    }

    function _deploy(uint256 component, bytes32 salt, bytes memory constructorArgs) private returns (address deployed) {
        address depot = codeDepots[component];
        if (depot.codehash != depotCodeHashes[component]) revert DepotCodeChanged(component);
        uint256 baseLength = depot.code.length;
        bytes memory creationCode = new bytes(baseLength + constructorArgs.length);
        assembly ("memory-safe") {
            extcodecopy(depot, add(creationCode, 0x20), 0, baseLength)
            let argsLength := mload(constructorArgs)
            let src := add(constructorArgs, 0x20)
            let dst := add(add(creationCode, 0x20), baseLength)
            for { let end := add(src, argsLength) } lt(src, end) {
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            } {
                mstore(dst, mload(src))
            }
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed(component);
    }
}

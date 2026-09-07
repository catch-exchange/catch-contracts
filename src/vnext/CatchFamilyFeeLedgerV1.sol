// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "../SafeTransferLib.sol";
import {ICatchAsset} from "../interfaces/ICatchAsset.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {ICatchFamilyFeeLedgerV1} from "./interfaces/ICatchFamilyFeeLedgerV1.sol";

/// @title cAsset immutable fee ledger
/// @notice Routes measured underlying and cAsset receipts for one cAsset family.
/// @dev Hook underlying, primary-release underlying and protocol-owned LP underlying split 70% to
///      the isolated reserve and 30% to treasury. Protocol-owned LP cAsset splits
///      70% to permanent burn and 30% to treasury cAsset. No caller can redirect
///      funds, mint cAsset or withdraw reserve assets through this contract.
contract CatchFamilyFeeLedgerV1 is ICatchFamilyFeeLedgerV1 {
    using SafeTransferLib for address;

    uint16 public constant NAV_BPS = 7_000;
    uint16 public constant TREASURY_BPS = 3_000;
    uint16 public constant LP_CASSET_BURN_BPS = 7_000;
    uint16 private constant BPS = 10_000;

    address public immutable underlying;
    ICatchAsset public immutable cAsset;
    address public immutable reserveVault;
    address public immutable treasury;
    address public immutable hook;
    address public immutable liquidityLocker;
    bytes32 public immutable hookCodeHash;
    bytes32 public immutable liquidityLockerCodeHash;
    address public immutable bindingAuthority;

    address public releaseController;
    uint256 public cumulativeHookUnderlying;
    uint256 public cumulativePrimaryUnderlying;
    uint256 public cumulativeLpUnderlying;
    uint256 public cumulativeNavUnderlying;
    uint256 public cumulativeTreasuryUnderlying;
    uint256 public cumulativeLpCAsset;
    uint256 public cumulativeLpCAssetBurned;
    uint256 public cumulativeTreasuryCAsset;
    uint256 private locked = 1;

    mapping(bytes32 => bool) public hookReceiptRecorded;
    mapping(bytes32 => bool) public primaryReceiptRecorded;
    mapping(bytes32 => bool) public lpCollectionRecorded;

    event ReleaseControllerBound(address indexed controller);
    event HookUnderlyingRouted(
        bytes32 indexed feeKey, uint256 feeUnderlying, uint256 navUnderlying, uint256 treasuryUnderlying
    );
    event PrimaryUnderlyingRouted(
        bytes32 indexed purchaseKey, uint256 paymentUnderlying, uint256 navUnderlying, uint256 treasuryUnderlying
    );
    event LpUnderlyingRouted(
        bytes32 indexed collectionKey, uint256 feeUnderlying, uint256 navUnderlying, uint256 treasuryUnderlying
    );
    event LpCAssetRouted(
        bytes32 indexed collectionKey, uint256 feeCAsset, uint256 burnedCAsset, uint256 treasuryCAsset
    );
    error AlreadyBound();
    error CodeHashChanged();
    error DeliveryMismatch();
    error DuplicateReceipt();
    error InvalidAmount();
    error NotBindingAuthority();
    error NotHook();
    error NotLiquidityLocker();
    error NotReleaseController();
    error Reentrancy();
    error ZeroAddress();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        address underlying_,
        address cAsset_,
        address reserveVault_,
        address treasury_,
        address hook_,
        address liquidityLocker_,
        address bindingAuthority_
    ) {
        if (
            underlying_ == address(0) || cAsset_ == address(0) || reserveVault_ == address(0) || treasury_ == address(0)
                || hook_ == address(0) || liquidityLocker_ == address(0) || bindingAuthority_ == address(0)
        ) revert ZeroAddress();
        if (hook_.code.length == 0 || liquidityLocker_.code.length == 0) revert ZeroAddress();
        underlying = underlying_;
        cAsset = ICatchAsset(cAsset_);
        reserveVault = reserveVault_;
        treasury = treasury_;
        hook = hook_;
        liquidityLocker = liquidityLocker_;
        hookCodeHash = hook_.codehash;
        liquidityLockerCodeHash = liquidityLocker_.codehash;
        bindingAuthority = bindingAuthority_;
    }

    /// @notice One-time factory binding for the paid primary-release controller.
    function bindReleaseController(address controller) external {
        if (msg.sender != bindingAuthority) revert NotBindingAuthority();
        if (releaseController != address(0)) revert AlreadyBound();
        if (controller == address(0) || controller.code.length == 0) revert ZeroAddress();
        releaseController = controller;
        emit ReleaseControllerBound(controller);
    }

    /// @notice Routes one permissionlessly flushed secondary-market hook receipt.
    function routeHookUnderlying(bytes32 feeKey, uint256 feeUnderlying) external nonReentrant {
        if (msg.sender != hook) revert NotHook();
        if (msg.sender.codehash != hookCodeHash) revert CodeHashChanged();
        if (feeKey == bytes32(0) || feeUnderlying == 0 || hookReceiptRecorded[feeKey]) revert DuplicateReceipt();

        (uint256 navUnderlying, uint256 treasuryUnderlying) = _routeUnderlyingFrom(msg.sender, feeUnderlying);
        hookReceiptRecorded[feeKey] = true;
        cumulativeHookUnderlying += feeUnderlying;
        emit HookUnderlyingRouted(feeKey, feeUnderlying, navUnderlying, treasuryUnderlying);
    }

    /// @notice Routes measured underlying paid for preminted primary-release inventory.
    function routePrimaryUnderlying(bytes32 purchaseKey, uint256 paymentUnderlying) external nonReentrant {
        if (msg.sender != releaseController) revert NotReleaseController();
        if (purchaseKey == bytes32(0) || paymentUnderlying == 0 || primaryReceiptRecorded[purchaseKey]) {
            revert DuplicateReceipt();
        }
        // Primary release increases active supply. Assign an indivisible underlying
        // remainder to NAV so integer rounding can never dilute backing.
        (uint256 navUnderlying, uint256 treasuryUnderlying) = _routeUnderlyingFrom(msg.sender, paymentUnderlying, true);
        primaryReceiptRecorded[purchaseKey] = true;
        cumulativePrimaryUnderlying += paymentUnderlying;
        emit PrimaryUnderlyingRouted(purchaseKey, paymentUnderlying, navUnderlying, treasuryUnderlying);
    }

    /// @notice Routes one unique underlying native-fee collection from permanent POL.
    /// @dev Callable only by the immutable locker; anyone may trigger collection
    ///      at the locker without gaining control over these destinations.
    function routeLpUnderlying(bytes32 collectionKey, uint256 feeUnderlying) external nonReentrant {
        _checkLocker(collectionKey, feeUnderlying);
        (uint256 navUnderlying, uint256 treasuryUnderlying) = _routeUnderlyingFrom(msg.sender, feeUnderlying);
        lpCollectionRecorded[collectionKey] = true;
        cumulativeLpUnderlying += feeUnderlying;
        emit LpUnderlyingRouted(collectionKey, feeUnderlying, navUnderlying, treasuryUnderlying);
    }

    /// @notice Burns and treasury-routes one unique cAsset native-fee collection.
    /// @dev The burn is permanent and no replacement inventory can be minted.
    function routeLpCAsset(bytes32 collectionKey, uint256 feeCAsset) external nonReentrant {
        _checkLocker(collectionKey, feeCAsset);
        uint256 burnAmount = feeCAsset * LP_CASSET_BURN_BPS / BPS;
        uint256 treasuryAmount = feeCAsset - burnAmount;

        uint256 ledgerBefore = cAsset.balanceOf(address(this));
        address(cAsset).safeTransferFrom(msg.sender, address(this), feeCAsset);
        if (cAsset.balanceOf(address(this)) - ledgerBefore != feeCAsset) revert DeliveryMismatch();
        uint256 supplyBefore = cAsset.totalSupply();
        cAsset.burn(burnAmount);
        if (supplyBefore - cAsset.totalSupply() != burnAmount) revert DeliveryMismatch();
        address(cAsset).safeTransfer(treasury, treasuryAmount);
        if (cAsset.balanceOf(address(this)) != ledgerBefore) revert DeliveryMismatch();

        lpCollectionRecorded[collectionKey] = true;
        cumulativeLpCAsset += feeCAsset;
        cumulativeLpCAssetBurned += burnAmount;
        cumulativeTreasuryCAsset += treasuryAmount;
        emit LpCAssetRouted(collectionKey, feeCAsset, burnAmount, treasuryAmount);
    }

    function _routeUnderlyingFrom(address payer, uint256 amount)
        private
        returns (uint256 navAmount, uint256 treasuryAmount)
    {
        return _routeUnderlyingFrom(payer, amount, false);
    }

    function _routeUnderlyingFrom(address payer, uint256 amount, bool roundNavUp)
        private
        returns (uint256 navAmount, uint256 treasuryAmount)
    {
        navAmount = amount * NAV_BPS / BPS;
        if (roundNavUp && mulmod(amount, NAV_BPS, BPS) != 0) ++navAmount;
        treasuryAmount = amount - navAmount;
        uint256 reserveBefore = IERC20Minimal(underlying).balanceOf(reserveVault);
        uint256 treasuryBefore = IERC20Minimal(underlying).balanceOf(treasury);
        underlying.safeTransferFrom(payer, reserveVault, navAmount);
        underlying.safeTransferFrom(payer, treasury, treasuryAmount);
        if (
            IERC20Minimal(underlying).balanceOf(reserveVault) - reserveBefore != navAmount
                || IERC20Minimal(underlying).balanceOf(treasury) - treasuryBefore != treasuryAmount
        ) revert DeliveryMismatch();
        cumulativeNavUnderlying += navAmount;
        cumulativeTreasuryUnderlying += treasuryAmount;
    }

    function _checkLocker(bytes32 collectionKey, uint256 amount) private view {
        if (msg.sender != liquidityLocker) revert NotLiquidityLocker();
        if (msg.sender.codehash != liquidityLockerCodeHash) revert CodeHashChanged();
        if (collectionKey == bytes32(0) || amount == 0) revert InvalidAmount();
        if (lpCollectionRecorded[collectionKey]) revert DuplicateReceipt();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "./SafeTransferLib.sol";
import {ICatchAsset} from "./interfaces/ICatchAsset.sol";
import {ICatchAssetEmissionVault} from "./interfaces/ICatchAssetEmissionVault.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

/// @title Catch isolated reserve vault
/// @notice Pays each active cAsset its pro-rata share of this family's fixed
///         underlying reserve and permanently burns the redeemed cAsset.
/// @dev Unreleased inventory is excluded from claim supply. The actual
///      underlying balance is the reserve, so an unsolicited transfer can only
///      increase claims. There is no sweep, pause, privileged recipient or
///      governance redemption path.
contract CatchAssetReserveVault {
    using SafeTransferLib for address;

    ICatchAsset public immutable cAsset;
    ICatchAssetEmissionVault public immutable emissionVault;
    address public immutable underlying;
    uint256 private locked = 1;

    event Redeemed(
        address indexed account,
        address indexed recipient,
        uint256 cAssetBurned,
        uint256 underlyingOut,
        uint256 activeClaimSupplyAfter
    );

    error InsufficientOutput();
    error InvalidCAssetDelivery();
    error InvalidAmount();
    error Reentrancy();
    error ZeroAddress();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(address cAsset_, address emissionVault_, address underlying_) {
        if (cAsset_ == address(0) || emissionVault_ == address(0) || underlying_ == address(0)) revert ZeroAddress();
        cAsset = ICatchAsset(cAsset_);
        emissionVault = ICatchAssetEmissionVault(emissionVault_);
        underlying = underlying_;
    }

    /// @notice Current supply entitled to reserve claims.
    function activeClaimSupply() public view returns (uint256) {
        return cAsset.totalSupply() - emissionVault.remainingEmission();
    }

    /// @notice Read-only redemption quote; no approval is required.
    function redemptionUnderlying(uint256 cAssetAmount) public view returns (uint256) {
        uint256 activeSupply = activeClaimSupply();
        if (cAssetAmount == 0 || activeSupply == 0) return 0;
        return cAssetAmount * IERC20Minimal(underlying).balanceOf(address(this)) / activeSupply;
    }

    /// @notice Burns approved cAsset and pays underlying to `recipient` atomically.
    function redeem(uint256 cAssetAmount, uint256 minimumUnderlyingOut, address recipient)
        external
        nonReentrant
        returns (uint256 underlyingOut)
    {
        if (cAssetAmount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();
        underlyingOut = redemptionUnderlying(cAssetAmount);
        if (underlyingOut == 0) revert InvalidAmount();
        if (underlyingOut < minimumUnderlyingOut) revert InsufficientOutput();

        uint256 recipientBalanceBefore = IERC20Minimal(underlying).balanceOf(recipient);
        uint256 cAssetBalanceBefore = cAsset.balanceOf(address(this));
        address(cAsset).safeTransferFrom(msg.sender, address(this), cAssetAmount);
        uint256 cAssetBalanceAfter = cAsset.balanceOf(address(this));
        if (cAssetBalanceAfter < cAssetBalanceBefore || cAssetBalanceAfter - cAssetBalanceBefore != cAssetAmount) {
            revert InvalidCAssetDelivery();
        }
        // Redemption burn only: pull the holder's claim into reserve-vault
        // custody, then destroy it. Native cAsset LP fees follow a separate path:
        // the permanent locker collects them and CatchFamilyFeeLedgerV1 burns 70%.
        // B20-style cAssets support the same custody-first redemption pattern
        // when their immutable reserve vault has the required burn authority.
        cAsset.burn(cAssetAmount);
        if (underlyingOut != 0) underlying.safeTransfer(recipient, underlyingOut);
        uint256 recipientBalanceAfter = IERC20Minimal(underlying).balanceOf(recipient);
        if (
            recipientBalanceAfter < recipientBalanceBefore
                || recipientBalanceAfter - recipientBalanceBefore < underlyingOut
        ) {
            revert InsufficientOutput();
        }
        emit Redeemed(msg.sender, recipient, cAssetAmount, underlyingOut, activeClaimSupply());
    }
}

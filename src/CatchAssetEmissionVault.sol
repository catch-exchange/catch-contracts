// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "./SafeTransferLib.sol";

/// @title Catch inactive release vault
/// @notice Holds the 900,000 preminted cAssets that are excluded from active
///         reserve claims until the one-time-bound controller releases them.
/// @dev The vault cannot mint, change controllers, withdraw arbitrarily or
///      replace inventory after burns. Only a paid primary purchase through the
///      bound release controller can move this inventory. The historical
///      contract and ABI use "emission" names; these mean paid release
///      inventory, not a secondary-trade reward.
contract CatchAssetEmissionVault {
    using SafeTransferLib for address;

    uint256 public constant EMISSION_CAP = 900_000 ether;

    address public immutable cAsset;
    address public immutable bindingAuthority;
    address public controller;
    uint256 public released;

    event ControllerBound(address indexed controller);
    event EmissionReleased(address indexed recipient, uint256 amount, uint256 cumulativeReleased);

    error AlreadyBound();
    error EmissionExceeded();
    error NotBindingAuthority();
    error NotController();
    error ZeroAddress();

    constructor(address cAsset_, address bindingAuthority_) {
        if (cAsset_ == address(0) || bindingAuthority_ == address(0)) revert ZeroAddress();
        cAsset = cAsset_;
        bindingAuthority = bindingAuthority_;
    }

    /// @notice Permanently binds the sole inventory-release controller.
    /// @dev Callable once by the construction authority; it is not governance.
    function bindController(address controller_) external {
        if (msg.sender != bindingAuthority) revert NotBindingAuthority();
        if (controller != address(0)) revert AlreadyBound();
        if (controller_ == address(0)) revert ZeroAddress();
        controller = controller_;
        emit ControllerBound(controller_);
    }

    /// @notice Preminted inventory not yet sold by the bound controller.
    function remainingEmission() public view returns (uint256) {
        return EMISSION_CAP - released;
    }

    /// @notice Transfers existing inventory under the bound controller's policy.
    function release(address recipient, uint256 amount) external {
        if (msg.sender != controller) revert NotController();
        if (recipient == address(0)) revert ZeroAddress();
        uint256 newReleased = released + amount;
        if (newReleased > EMISSION_CAP) revert EmissionExceeded();
        released = newReleased;
        if (amount != 0) cAsset.safeTransfer(recipient, amount);
        emit EmissionReleased(recipient, amount, newReleased);
    }
}

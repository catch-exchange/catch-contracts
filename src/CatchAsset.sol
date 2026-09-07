// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICatchAsset} from "./interfaces/ICatchAsset.sol";

/// @title Catch cAsset
/// @notice Fixed-supply cAsset whose name and symbol are bound per family.
/// @dev Voluntary burns destroy a holder's claim without paying its underlying. Asset
///      redemption is a separate reserve-vault operation that pulls the user's
///      approved cAsset into vault custody, burns it, and pays the underlying
///      atomically. `burnFromReserve` remains available for the original family
///      binding but is not required by the generic redemption path.
contract CatchAsset is ICatchAsset {
    string public override name;
    string public override symbol;
    uint8 public constant override decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;

    uint256 public override totalSupply = INITIAL_SUPPLY;
    address public reserveVault;
    address public immutable bindingAuthority;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event ReserveVaultBound(address indexed reserveVault);

    error AlreadyBound();
    error EmptyMetadata();
    error InsufficientAllowance();
    error InsufficientBalance();
    error NotBindingAuthority();
    error NotReserveVault();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, address supplyRecipient, address bindingAuthority_) {
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyMetadata();
        if (supplyRecipient == address(0) || bindingAuthority_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        bindingAuthority = bindingAuthority_;
        balanceOf[supplyRecipient] = INITIAL_SUPPLY;
        emit Transfer(address(0), supplyRecipient, INITIAL_SUPPLY);
    }

    function bindReserveVault(address reserveVault_) external {
        if (msg.sender != bindingAuthority) revert NotBindingAuthority();
        if (reserveVault != address(0)) revert AlreadyBound();
        if (reserveVault_ == address(0)) revert ZeroAddress();
        reserveVault = reserveVault_;
        emit ReserveVaultBound(reserveVault_);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _spendAllowance(sender, msg.sender, amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    /// @notice Permanently destroys the caller's cAsset without redeeming its underlying.
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    /// @notice Permanently destroys approved cAsset without redeeming its underlying.
    function burnFrom(address account, uint256 amount) external override {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    /// @notice Burns claims as the final accounting leg of reserve redemption.
    /// @dev The reserve vault is bound once and is the only caller allowed to
    ///      use this allowance-free path.
    function burnFromReserve(address account, uint256 amount) external override {
        if (msg.sender != reserveVault) revert NotReserveVault();
        _burn(account, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        if (sender == address(0) || recipient == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[sender];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[sender] = balance - amount;
            balanceOf[recipient] += amount;
        }
        emit Transfer(sender, recipient, amount);
    }

    function _burn(address account, uint256 amount) private {
        if (account == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[account];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[account] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 allowed = allowance[owner][spender];
        if (allowed == type(uint256).max) return;
        if (allowed < amount) revert InsufficientAllowance();
        unchecked {
            allowance[owner][spender] = allowed - amount;
        }
    }
}

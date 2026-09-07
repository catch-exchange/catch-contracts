// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title cAsset immutable accounting boundary
/// @notice Accepts measured receipts only from the bound hook, release
///         controller and permanent-liquidity locker.
interface ICatchFamilyFeeLedgerV1 {
    /// @notice Routes a unique aggregate underlying receipt collected by the 3% hook.
    function routeHookUnderlying(bytes32 feeKey, uint256 feeUnderlying) external;

    /// @notice Routes a unique underlying payment for preminted primary inventory.
    function routePrimaryUnderlying(bytes32 purchaseKey, uint256 paymentUnderlying) external;

    /// @notice Routes protocol-owned native LP fees received in underlying.
    function routeLpUnderlying(bytes32 collectionKey, uint256 feeUnderlying) external;

    /// @notice Routes protocol-owned native LP fees received in cAsset.
    function routeLpCAsset(bytes32 collectionKey, uint256 feeCAsset) external;
}

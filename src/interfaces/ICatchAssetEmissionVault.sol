// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICatchAssetEmissionVault {
    function cAsset() external view returns (address);
    function remainingEmission() external view returns (uint256);
    function released() external view returns (uint256);
    function release(address recipient, uint256 amount) external;
}

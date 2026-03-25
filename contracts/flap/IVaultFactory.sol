// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IVaultFactory {
    error OnlyVaultPortal();
    error ZeroAddress();
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData) external returns (address vault);
    function isQuoteTokenSupported(address quoteToken) external view returns (bool supported);
}

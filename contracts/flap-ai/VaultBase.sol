// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VaultBase — Flap Vault Specification V1
abstract contract VaultBase {
    error UnsupportedChain(uint256 chainId);

    function _getPortal() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56) return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        if (id == 97) return 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        revert UnsupportedChain(id);
    }

    function _getGuardian() internal view returns (address) {
        uint256 id = block.chainid;
        if (id == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (id == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        revert UnsupportedChain(id);
    }

    function description() public view virtual returns (string memory);
}

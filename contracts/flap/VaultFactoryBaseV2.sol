// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBase} from "./VaultBase.sol";
import {IVaultFactory} from "./IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor} from "./VaultBaseV2.sol";

abstract contract VaultFactoryBaseV2 is IVaultFactory {
    function vaultDataSchema() public pure virtual returns (VaultDataSchema memory schema);
}

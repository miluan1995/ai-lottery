// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBase} from "./VaultBase.sol";

struct FieldDescriptor { string name; string fieldType; string description; uint8 decimals; }
struct ApproveAction { string tokenFieldName; string amountFieldName; }
struct VaultMethodSchema {
    string name; string description;
    FieldDescriptor[] inputs; FieldDescriptor[] outputs;
    ApproveAction[] approvals; bool isWriteMethod;
}
struct VaultUISchema { string vaultType; string description; VaultMethodSchema[] methods; }
struct VaultDataSchema { string description; FieldDescriptor[] fields; bool isArray; }

abstract contract VaultBaseV2 is VaultBase {
    function vaultUISchema() public pure virtual returns (VaultUISchema memory schema);
}

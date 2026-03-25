// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/VaultBaseV2.sol";
import {AILotteryVaultV2} from "./AILotteryVaultV2.sol";

/// @title AILotteryVaultV2Factory
/// @notice Deploys AILotteryVaultV2 instances via VaultPortal.
///         No SplitVault needed — V2 handles pool/reserve/dev split internally.
contract AILotteryVaultV2Factory is VaultFactoryBaseV2 {
    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);

    address public immutable portal;

    constructor() {
        uint256 chainId = block.chainid;
        if (chainId == 56) portal = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06; // VaultPortal BSC
        else if (chainId == 97) portal = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f; // VaultPortal BSC Testnet
        else revert("unsupported chain");
    }

    /// @notice VaultPortal calls this to deploy a new AILotteryVaultV2
    /// @param creator The token creator (becomes dev + owner of vault)
    /// @param vaultData ABI-encoded (uint256 minBal, uint256 cooldown)
    function newVault(address /*taxToken*/, address /*quoteToken*/, address creator, bytes calldata vaultData)
        external override returns (address vault)
    {
        if (msg.sender != portal) revert OnlyVaultPortal();
        (uint256 minBal, uint256 cooldown) = abi.decode(vaultData, (uint256, uint256));
        AILotteryVaultV2 v = new AILotteryVaultV2(creator, minBal, cooldown);
        vault = address(v);
        emit VaultCreated(vault, address(0), creator);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0); // BNB only
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"AI Lottery Vault V2 — AI Oracle picks a winner every hour, 60% of pool as prize. "
            unicode"Tax split: 50% pool / 40% next round / 10% dev. Built-in Oracle integration. / "
            unicode"AI彩票金库V2 — 每小时AI预言机开奖，奖池60%发给赢家。税收分配：50%奖池/40%下期/10%开发者。内置Oracle。";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("minBal", "uint256", "Min BNB balance to auto-request Oracle (wei)", 0);
        schema.fields[1] = FieldDescriptor("cooldown", "uint256", "Seconds between draws (e.g. 3600 = 1 hour)", 0);
        schema.isArray = false;
    }
}

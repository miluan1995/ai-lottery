// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/VaultBaseV2.sol";
import {AILotteryVault} from "./AILotteryVault.sol";

/// @title AILotteryVaultFactory
/// @notice Deploys AILotteryVault instances for flap.sh token launches.
contract AILotteryVaultFactory is VaultFactoryBaseV2 {
    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);

    address public immutable portal;

    constructor() {
        uint256 chainId = block.chainid;
        if (chainId == 56) portal = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        else if (chainId == 97) portal = 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        else revert("unsupported chain");
    }

    function newVault(address taxToken, address /*quoteToken*/, address creator, bytes calldata vaultData)
        external override returns (address vault)
    {
        if (msg.sender != portal) revert OnlyVaultPortal();
        address oracle = abi.decode(vaultData, (address));
        AILotteryVault v = new AILotteryVault(creator, oracle);
        v.setTaxToken(taxToken);
        vault = address(v);
        emit VaultCreated(vault, taxToken, creator);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0); // BNB only
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"AI Lottery Vault — AI Oracle picks a winner every hour, 60% of pool as prize. "
            unicode"Tax split: 50% pool / 40% next round / 10% dev. / "
            unicode"AI彩票金库 — 每小时AI开奖，奖池60%发给赢家。税收分配：50%奖池/40%下期/10%开发者。";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor("oracle", "address", "Oracle address that triggers draws", 0);
        schema.isArray = false;
    }
}

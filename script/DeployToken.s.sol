// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

interface IPortalTypes {
    enum DexThreshType { TWO_THIRDS, FOUR_FIFTHS, HALF, _95_PERCENT, _81_PERCENT, _1_PERCENT }
    enum MigratorType { NONE }
    enum DEXId { DEFAULT }
    enum V3LPFeeProfile { DEFAULT }
}

interface IVaultPortal {
    struct NewTaxTokenWithVaultParams {
        string name;
        string symbol;
        string meta;
        IPortalTypes.DexThreshType dexThresh;
        bytes32 salt;
        uint16 taxRate;
        IPortalTypes.MigratorType migratorType;
        address quoteToken;
        uint256 quoteAmt;
        bytes permitData;
        bytes32 extensionID;
        bytes extensionData;
        IPortalTypes.DEXId dexId;
        IPortalTypes.V3LPFeeProfile lpFeeProfile;
        uint64 taxDuration;
        uint64 antiFarmerDuration;
        uint16 mktBps;
        uint16 deflationBps;
        uint16 dividendBps;
        uint16 lpBps;
        uint256 minimumShareBalance;
        address vaultFactory;
        bytes vaultData;
    }

    function newTaxTokenWithVault(NewTaxTokenWithVaultParams calldata params) external payable returns (address token, address vault);
}

contract DeployToken is Script {
    function run() external {
        address deployer = msg.sender;
        
        // VaultPortal on BSC mainnet
        IVaultPortal portal = IVaultPortal(0x90497450f2a706f1951b5bdda52B4E5d16f34C06);
        
        // Our factory
        address factory = 0xa25F406B0630E1C2139BC020145966De4FC47502;
        
        // Oracle = deployer wallet
        bytes memory vaultData = abi.encode(deployer);

        IVaultPortal.NewTaxTokenWithVaultParams memory params = IVaultPortal.NewTaxTokenWithVaultParams({
            name: "AI Lottery",
            symbol: "AILOT",
            meta: "AI-powered lottery on BNB Chain. Every hour, AI Oracle picks a winner.",
            dexThresh: IPortalTypes.DexThreshType.TWO_THIRDS,
            salt: bytes32(uint256(1)),  // will need vanity mining
            taxRate: 1000,              // 10% = 1000 bps
            migratorType: IPortalTypes.MigratorType.NONE,
            quoteToken: address(0),     // BNB
            quoteAmt: 0,
            permitData: "",
            extensionID: bytes32(0),
            extensionData: "",
            dexId: IPortalTypes.DEXId.DEFAULT,
            lpFeeProfile: IPortalTypes.V3LPFeeProfile.DEFAULT,
            taxDuration: 315360000,     // ~10 years
            antiFarmerDuration: 300,    // 5 min
            mktBps: 10000,             // 100% of tax to vault (mkt = vault recipient)
            deflationBps: 0,
            dividendBps: 0,
            lpBps: 0,
            minimumShareBalance: 0,
            vaultFactory: factory,
            vaultData: vaultData
        });

        vm.startBroadcast();
        (address token, address vault) = portal.newTaxTokenWithVault(params);
        vm.stopBroadcast();

        console.log("Token:", token);
        console.log("Vault:", vault);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/trading/TapToTradeExecutor.sol";

contract DeployTapToTradeExecutor is Script {
    function run() external {
        // Load addresses from environment
        address usdc = vm.envAddress("USDC_ADDRESS");
        address riskManager = vm.envAddress("RISK_MANAGER_ADDRESS");
        address positionManager = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address treasuryManager = vm.envAddress("TREASURY_MANAGER_ADDRESS");
        address backendSigner = vm.envAddress("BACKEND_SIGNER_ADDRESS");

        console.log("Deploying TapToTradeExecutor with:");
        console.log("  USDC:", usdc);
        console.log("  RiskManager:", riskManager);
        console.log("  PositionManager:", positionManager);
        console.log("  TreasuryManager:", treasuryManager);
        console.log("  BackendSigner:", backendSigner);

        vm.startBroadcast();

        TapToTradeExecutor tapToTradeExecutor = new TapToTradeExecutor(
            usdc,
            riskManager,
            positionManager,
            treasuryManager,
            backendSigner
        );

        console.log("\n==============================================");
        console.log("TapToTradeExecutor deployed at:", address(tapToTradeExecutor));
        console.log("==============================================\n");

        console.log("Next steps:");
        console.log("1. Update frontend .env:");
        console.log("   NEXT_PUBLIC_TAP_TO_TRADE_EXECUTOR_ADDRESS=%s", address(tapToTradeExecutor));
        console.log("\n2. Update backend .env:");
        console.log("   TAP_TO_TRADE_EXECUTOR_ADDRESS=%s", address(tapToTradeExecutor));
        console.log("\n3. Copy ABI:");
        console.log("   cp out/TapToTradeExecutor.sol/TapToTradeExecutor.json ../tethra-be/src/abis/");

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/trading/LimitExecutor.sol";

contract DeployLimitExecutor is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Read existing contract addresses from environment
        address usdc = vm.envAddress("USDC_ADDRESS");
        address riskManager = vm.envAddress("RISK_MANAGER_ADDRESS");
        address positionManager = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address treasuryManager = vm.envAddress("TREASURY_MANAGER_ADDRESS");
        // Allow defaulting to deployer if env vars are not set
        address keeper = vm.envOr("KEEPER_ADDRESS", deployer);
        address backendSigner = vm.envOr("BACKEND_SIGNER_ADDRESS", deployer);

        console.log("=== DEPLOYMENT CONFIG ===");
        console.log("Deployer        :", deployer);
        console.log("USDC            :", usdc);
        console.log("RiskManager     :", riskManager);
        console.log("PositionManager :", positionManager);
        console.log("TreasuryManager :", treasuryManager);
        console.log("Keeper          :", keeper);
        // console.log("BackendSigner   :", backendSigner);

        // Validate all addresses are set
        require(usdc != address(0), "USDC_ADDRESS not set");
        require(riskManager != address(0), "RISK_MANAGER_ADDRESS not set");
        require(positionManager != address(0), "POSITION_MANAGER_ADDRESS not set");
        require(treasuryManager != address(0), "TREASURY_MANAGER_ADDRESS not set");
        require(keeper != address(0), "KEEPER_ADDRESS not set (or defaulted to deployer)");
        require(backendSigner != address(0), "BACKEND_SIGNER_ADDRESS not set (or defaulted to deployer)");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy LimitExecutor only
        console.log("\n=== DEPLOYING LIMIT EXECUTOR ===");
        LimitExecutor limitExecutor =
            new LimitExecutor(usdc, riskManager, positionManager, treasuryManager, keeper, backendSigner);

        console.log("LimitExecutor deployed at:", address(limitExecutor));
        console.log("Contract size:", address(limitExecutor).code.length, "bytes");

        vm.stopBroadcast();

        // Print integration instructions
        console.log("\n=== INTEGRATION REQUIRED ===");
        console.log("You need to manually grant roles in existing contracts:");
        console.log("");
        console.log("1. PositionManager - Grant EXECUTOR_ROLE:");
        console.log("   positionManager.grantRole(EXECUTOR_ROLE, %s);", address(limitExecutor));
        console.log("");
        console.log("2. TreasuryManager - Grant EXECUTOR_ROLE:");
        console.log("   treasuryManager.grantRole(EXECUTOR_ROLE, %s);", address(limitExecutor));
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Contract Address: %s", address(limitExecutor));
        console.log("Network         : Base Sepolia (84532)");
        console.log("Gas Used        : %s", tx.gasprice);
        console.log("");
        console.log("LimitExecutor deployed successfully!");
        console.log("Don't forget to set up roles in existing contracts!");
    }
}

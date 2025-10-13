// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/trading/LimitExecutorV2.sol";

/**
 * @title DeployLimitExecutorV2
 * @notice Foundry script to deploy the dynamic-fee LimitExecutorV2 contract
 *
 * Environment variables:
 *  - PRIVATE_KEY              : Deployer private key (required)
 *  - USDC_ADDRESS             : USDC token address (required)
 *  - RISK_MANAGER_ADDRESS     : RiskManager address (required)
 *  - POSITION_MANAGER_ADDRESS : PositionManager address (required)
 *  - TREASURY_MANAGER_ADDRESS : TreasuryManager address (required)
 *  - KEEPER_ADDRESS           : Keeper wallet (optional, defaults to deployer)
 *  - BACKEND_SIGNER_ADDRESS   : Backend price signer (optional, defaults to deployer)
 *
 * Example:
 * forge script script/DeployLimitExecutorV2.s.sol \
 *   --rpc-url $BASE_SEPOLIA_RPC \
 *   --broadcast \
 *   --verify
 */
contract DeployLimitExecutorV2 is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        address usdc = vm.envAddress("USDC_ADDRESS");
        address riskManager = vm.envAddress("RISK_MANAGER_ADDRESS");
        address positionManager = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address treasuryManager = vm.envAddress("TREASURY_MANAGER_ADDRESS");

        address keeper = vm.envOr("KEEPER_ADDRESS", deployer);
        address backendSigner = vm.envOr("BACKEND_SIGNER_ADDRESS", deployer);

        _validateAddress(usdc, "USDC_ADDRESS");
        _validateAddress(riskManager, "RISK_MANAGER_ADDRESS");
        _validateAddress(positionManager, "POSITION_MANAGER_ADDRESS");
        _validateAddress(treasuryManager, "TREASURY_MANAGER_ADDRESS");
        _validateAddress(keeper, "KEEPER_ADDRESS");
        _validateAddress(backendSigner, "BACKEND_SIGNER_ADDRESS");

        console.log("\n==============================================");
        console.log("         LIMIT EXECUTOR V2 DEPLOYMENT");
        console.log("==============================================\n");
        console.log("Deployer             :", deployer);
        console.log("Keeper               :", keeper);
        console.log("Backend signer       :", backendSigner);
        console.log("");
        console.log("Using dependencies:");
        console.log("  USDC               :", usdc);
        console.log("  RiskManager        :", riskManager);
        console.log("  PositionManager    :", positionManager);
        console.log("  TreasuryManager    :", treasuryManager);
        console.log("");

        vm.startBroadcast(deployerPk);
        LimitExecutorV2 limitExecutor =
            new LimitExecutorV2(usdc, riskManager, positionManager, treasuryManager, keeper, backendSigner);
        vm.stopBroadcast();

        console.log("LimitExecutorV2 deployed at:", address(limitExecutor));
        console.log("\nNext steps:");
        console.log("  1. Grant EXECUTOR_ROLE to the new contract on PositionManager.");
        console.log("  2. Grant EXECUTOR_ROLE on TreasuryManager.");
        console.log("  3. Update frontend/backend configs with the new address.");
        console.log("  4. Ensure keepers read dynamic execution fee recommendations.");
        console.log("");

        _writeDeploymentSummary(
            limitExecutor, deployer, keeper, backendSigner, usdc, riskManager, positionManager, treasuryManager
        );
    }

    function _writeDeploymentSummary(
        LimitExecutorV2 limitExecutor,
        address deployer,
        address keeper,
        address backendSigner,
        address usdc,
        address riskManager,
        address positionManager,
        address treasuryManager
    ) internal {
        string memory filename = string.concat(
            "./deployments/LimitExecutorV2-", vm.toString(block.chainid), "-", vm.toString(block.timestamp), ".md"
        );

        string memory content = string.concat(
            "# LimitExecutorV2 Deployment\n\n",
            "## Addresses\n",
            "- LimitExecutorV2: ",
            vm.toString(address(limitExecutor)),
            "\n",
            "- USDC: ",
            vm.toString(usdc),
            "\n",
            "- RiskManager: ",
            vm.toString(riskManager),
            "\n",
            "- PositionManager: ",
            vm.toString(positionManager),
            "\n",
            "- TreasuryManager: ",
            vm.toString(treasuryManager),
            "\n\n",
            "## Roles\n",
            "- Admin (DEFAULT_ADMIN_ROLE): ",
            vm.toString(deployer),
            "\n",
            "- Keeper (KEEPER_ROLE): ",
            vm.toString(keeper),
            "\n",
            "- Backend signer (BACKEND_SIGNER_ROLE): ",
            vm.toString(backendSigner),
            "\n\n",
            "## Parameters\n",
            "- Trading fee (bps): ",
            vm.toString(limitExecutor.tradingFeeBps()),
            "\n",
            "- Price validity window: ",
            vm.toString(limitExecutor.PRICE_VALIDITY_WINDOW()),
            " seconds\n",
            "- Order validity period: ",
            vm.toString(limitExecutor.ORDER_VALIDITY_PERIOD()),
            " seconds\n",
            "- Execution fee: **dynamic per order** (set via user signature & keeper input)\n\n",
            "## Follow-up Checklist\n",
            "1. Grant EXECUTOR_ROLE on PositionManager\n",
            "2. Grant EXECUTOR_ROLE on TreasuryManager\n",
            "3. Update dApp configs with new contract address\n",
            "4. Ensure backend keeper consumes `/api/relay/limit/execution-fee`\n",
            "5. Regenerate ABI: `forge inspect src/trading/LimitExecutorV2.sol:LimitExecutorV2 abi`\n"
        );

        vm.createDir("./deployments", true);
        vm.writeFile(filename, content);
        console.log("Deployment summary written to:", filename);
    }

    function _validateAddress(address account, string memory label) internal pure {
        require(account != address(0), string.concat(label, " not set"));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {RiskManager} from "../src/risk/RiskManager.sol";
import {MarketExecutor} from "../src/trading/MarketExecutor.sol";
import {LimitExecutorV2} from "../src/trading/LimitExecutorV2.sol";
interface IAccessControlled {
    function grantRole(bytes32 role, address account) external;
    function EXECUTOR_ROLE() external view returns (bytes32);
}

/**
 * @title DeployTradingExecutors
 * @notice Deploys RiskManager, MarketExecutor, and LimitExecutorV2 in one run.
 *
 * Required environment variables:
 *  - PRIVATE_KEY               : Deployer private key
 *  - USDC_ADDRESS              : USDC token address
 *  - POSITION_MANAGER_ADDRESS  : Existing PositionManager contract
 *  - TREASURY_MANAGER_ADDRESS  : Existing TreasuryManager contract
 *
 * Optional environment variables:
 *  - KEEPER_ADDRESS            : Keeper wallet for limit orders (defaults to deployer)
 *  - BACKEND_SIGNER_ADDRESS    : Backend price signer (defaults to deployer)
 *
 * Example:
 * forge script script/DeployTradingExecutors.s.sol \\
 *   --rpc-url $BASE_SEPOLIA_RPC \\
 *   --broadcast \\
 *   --verify
 */
contract DeployTradingExecutors is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        address usdc = vm.envAddress("USDC_ADDRESS");
        address positionManagerAddress = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address treasuryManagerAddress = vm.envAddress("TREASURY_MANAGER_ADDRESS");

        address keeper = vm.envOr("KEEPER_ADDRESS", deployer);
        address backendSigner = vm.envOr("BACKEND_SIGNER_ADDRESS", deployer);

        _validateAddress(usdc, "USDC_ADDRESS");
        _validateAddress(positionManagerAddress, "POSITION_MANAGER_ADDRESS");
        _validateAddress(treasuryManagerAddress, "TREASURY_MANAGER_ADDRESS");
        _validateAddress(keeper, "KEEPER_ADDRESS");
        _validateAddress(backendSigner, "BACKEND_SIGNER_ADDRESS");

        console.log("\n================================================");
        console.log("    TRADING STACK DEPLOYMENT (RISK/EXECUTORS)");
        console.log("================================================\n");

        console.log("Deployer            :", deployer);
        console.log("Keeper              :", keeper);
        console.log("Backend signer      :", backendSigner);
        console.log("");
        console.log("Using dependencies:");
        console.log("  USDC              :", usdc);
        console.log("  PositionManager   :", positionManagerAddress);
        console.log("  TreasuryManager   :", treasuryManagerAddress);
        console.log("");

        vm.startBroadcast(deployerPk);

        RiskManager riskManager = new RiskManager();
        console.log("[1/3] RiskManager deployed at :", address(riskManager));

        MarketExecutor marketExecutor = new MarketExecutor(
            usdc, address(riskManager), positionManagerAddress, treasuryManagerAddress, backendSigner
        );
        console.log("[2/3] MarketExecutor deployed at :", address(marketExecutor));

        LimitExecutorV2 limitExecutor = new LimitExecutorV2(
            usdc, address(riskManager), positionManagerAddress, treasuryManagerAddress, keeper, backendSigner
        );
        console.log("[3/3] LimitExecutorV2 deployed at :", address(limitExecutor));

        _attemptRoleGrant(positionManagerAddress, treasuryManagerAddress, marketExecutor, limitExecutor);

        vm.stopBroadcast();

        _writeDeploymentSummary(
            deployer,
            usdc,
            positionManagerAddress,
            treasuryManagerAddress,
            address(riskManager),
            address(marketExecutor),
            address(limitExecutor),
            keeper,
            backendSigner
        );
    }

    function _attemptRoleGrant(
        address positionManagerAddress,
        address treasuryManagerAddress,
        MarketExecutor marketExecutor,
        LimitExecutorV2 limitExecutor
    ) internal {
        IAccessControlled positionManager = IAccessControlled(positionManagerAddress);
        IAccessControlled treasuryManager = IAccessControlled(treasuryManagerAddress);

        bytes32 executorRolePosition = positionManager.EXECUTOR_ROLE();
        bytes32 executorRoleTreasury = treasuryManager.EXECUTOR_ROLE();

        // PositionManager role grant attempts
        try positionManager.grantRole(executorRolePosition, address(marketExecutor)) {
            console.log("PositionManager: granted EXECUTOR_ROLE to MarketExecutor");
        } catch {
            console.log("WARN: PositionManager grant to MarketExecutor failed (check admin permissions)");
        }

        try positionManager.grantRole(executorRolePosition, address(limitExecutor)) {
            console.log("PositionManager: granted EXECUTOR_ROLE to LimitExecutorV2");
        } catch {
            console.log("WARN: PositionManager grant to LimitExecutorV2 failed (check admin permissions)");
        }

        // TreasuryManager role grant attempts
        try treasuryManager.grantRole(executorRoleTreasury, address(marketExecutor)) {
            console.log("TreasuryManager: granted EXECUTOR_ROLE to MarketExecutor");
        } catch {
            console.log("WARN: TreasuryManager grant to MarketExecutor failed (check admin permissions)");
        }

        try treasuryManager.grantRole(executorRoleTreasury, address(limitExecutor)) {
            console.log("TreasuryManager: granted EXECUTOR_ROLE to LimitExecutorV2");
        } catch {
            console.log("WARN: TreasuryManager grant to LimitExecutorV2 failed (check admin permissions)");
        }
    }

    function _writeDeploymentSummary(
        address deployer,
        address usdc,
        address positionManager,
        address treasuryManager,
        address riskManager,
        address marketExecutor,
        address limitExecutor,
        address keeper,
        address backendSigner
    ) internal {
        string memory filename = string.concat(
            "./deployments/TradingExecutors-",
            vm.toString(block.chainid),
            "-",
            vm.toString(block.timestamp),
            ".md"
        );

        string memory content = string.concat(
            "# Trading Executors Deployment\n\n",
            "## Newly Deployed Contracts\n",
            "- RiskManager: ",
            vm.toString(riskManager),
            "\n",
            "- MarketExecutor: ",
            vm.toString(marketExecutor),
            "\n",
            "- LimitExecutorV2: ",
            vm.toString(limitExecutor),
            "\n\n",
            "## External Dependencies\n",
            "- USDC: ",
            vm.toString(usdc),
            "\n",
            "- PositionManager: ",
            vm.toString(positionManager),
            "\n",
            "- TreasuryManager: ",
            vm.toString(treasuryManager),
            "\n\n",
            "## Roles\n",
            "- Deployer (DEFAULT_ADMIN_ROLE): ",
            vm.toString(deployer),
            "\n",
            "- Keeper (LimitExecutorV2 KEEPER_ROLE): ",
            vm.toString(keeper),
            "\n",
            "- Backend signer (BACKEND_SIGNER_ROLE): ",
            vm.toString(backendSigner),
            "\n\n",
            "## Follow-up Checklist\n",
            "1. Confirm EXECUTOR_ROLE assignments on PositionManager and TreasuryManager.\n",
            "2. Configure RiskManager asset parameters via `setAssetConfig`.\n",
            "3. Update backend/front-end environment files with new contract addresses.\n",
            "4. Fund treasury/keepers as needed.\n",
            "5. (Optional) Verify contracts on block explorer using `forge verify-contract`.\n"
        );

        vm.createDir("./deployments", true);
        vm.writeFile(filename, content);
        console.log("\nDeployment summary written to:", filename);
    }

    function _validateAddress(address account, string memory label) internal pure {
        require(account != address(0), string.concat(label, " not set"));
    }
}

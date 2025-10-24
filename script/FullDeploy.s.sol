// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/token/MockUSDC.sol";
import "../src/token/TethraToken.sol";
import "../src/risk/RiskManager.sol";
import "../src/trading/PositionManager.sol";
import "../src/treasury/TreasuryManager.sol";
import "../src/trading/MarketExecutor.sol";
import {LimitExecutorV2 as LimitExecutorV2Contract} from "../src/trading/LimitExecutorV2.sol";
import {TapToTradeExecutor as TapToTradeExecutorContract} from "../src/trading/TapToTradeExecutor.sol";
import {OneTapProfit as OneTapProfitContract} from "../src/trading/OneTapProfit.sol";
import "../src/paymaster/USDCPaymaster.sol";
import "../src/staking/TethraStaking.sol";
import "../src/staking/LiquidityMining.sol";

/**
 * @title FullDeploy
 * @notice Complete deployment script for Tethra DEX with automatic role grants
 * @dev Deploys all contracts, grants roles, and initializes token distribution
 *
 * Usage:
 * forge script script/FullDeploy.s.sol \
 *   --rpc-url https://sepolia.base.org \
 *   --private-key YOUR_PRIVATE_KEY \
 *   --broadcast
 */
contract FullDeploy is Script {
    // Contract instances
    MockUSDC public mockUSDC;
    TethraToken public tethraToken;
    RiskManager public riskManager;
    PositionManager public positionManager;
    TreasuryManager public treasuryManager;
    MarketExecutor public marketExecutor;
    LimitExecutorV2Contract public limitExecutor;
    TapToTradeExecutorContract public tapToTradeExecutor;
    OneTapProfitContract public oneTapProfit;
    USDCPaymaster public usdcPaymaster;
    TethraStaking public tethraStaking;
    LiquidityMining public liquidityMining;

    // Addresses
    address public deployer;
    address public teamWallet;
    address public protocolTreasury;
    address public keeperWallet;
    address public priceSignerWallet;

    function run() external {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // Setup addresses (can be env vars or use deployer as default)
        try vm.envAddress("TEAM_WALLET") returns (address _team) {
            teamWallet = _team;
        } catch {
            teamWallet = deployer; // Default to deployer
        }

        try vm.envAddress("PROTOCOL_TREASURY") returns (address _treasury) {
            protocolTreasury = _treasury;
        } catch {
            protocolTreasury = deployer;
        }

        try vm.envAddress("KEEPER_WALLET") returns (address _keeper) {
            keeperWallet = _keeper;
        } catch {
            keeperWallet = deployer;
        }

        try vm.envAddress("PRICE_SIGNER_WALLET") returns (address _signer) {
            priceSignerWallet = _signer;
        } catch {
            priceSignerWallet = deployer;
        }

        console.log("=================================================");
        console.log("Tethra DEX - Full Deployment Script");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("Team Wallet:", teamWallet);
        console.log("Protocol Treasury:", protocolTreasury);
        console.log("Keeper Wallet:", keeperWallet);
        console.log("Price Signer:", priceSignerWallet);
        console.log("=================================================\n");

        vm.startBroadcast();

        // Step 1: Deploy Token Contracts
        console.log("Step 1/5: Deploying Token Contracts...");
        deployTokens();

        // Step 2: Deploy Core Trading Contracts
        console.log("\nStep 2/5: Deploying Core Trading Contracts...");
        deployCoreContracts();

        // Step 3: Deploy Advanced Trading Contracts
        console.log("\nStep 3/5: Deploying Advanced Trading Contracts...");
        deployAdvancedTrading();

        // Step 4: Deploy Staking & Incentive Contracts
        console.log("\nStep 4/5: Deploying Staking & Incentive Contracts...");
        deployStakingContracts();

        // Step 5: Setup Roles & Initialize
        console.log("\nStep 5/5: Setting up Roles & Initializing...");
        setupRolesAndInitialize();

        vm.stopBroadcast();

        // Print deployment summary
        printDeploymentSummary();

        // Save deployment to JSON
        saveDeployment();
    }

    function deployTokens() internal {
        // Deploy Mock USDC (testnet only) - 10M initial supply
        mockUSDC = new MockUSDC(10_000_000);
        console.log("  MockUSDC deployed:", address(mockUSDC));

        // Deploy Tethra Token
        tethraToken = new TethraToken();
        console.log("  TethraToken deployed:", address(tethraToken));
    }

    function deployCoreContracts() internal {
        // Deploy RiskManager
        riskManager = new RiskManager();
        console.log("  RiskManager deployed:", address(riskManager));

        // Deploy PositionManager (no constructor params)
        positionManager = new PositionManager();
        console.log("  PositionManager deployed:", address(positionManager));

        // Deploy TreasuryManager
        treasuryManager = new TreasuryManager(
            address(mockUSDC),
            address(0), // Staking address - will update later
            protocolTreasury
        );
        console.log("  TreasuryManager deployed:", address(treasuryManager));

        // Deploy MarketExecutor (needs backendSigner)
        marketExecutor = new MarketExecutor(
            address(mockUSDC),
            address(riskManager),
            address(positionManager),
            address(treasuryManager),
            priceSignerWallet // backendSigner
        );
        console.log("  MarketExecutor deployed:", address(marketExecutor));

        // Deploy USDCPaymaster (needs usdcPerEth rate, e.g., 3000 USDC per ETH)
        usdcPaymaster = new USDCPaymaster(
            address(mockUSDC),
            3000_000000 // 3000 USDC per ETH (6 decimals)
        );
        console.log("  USDCPaymaster deployed:", address(usdcPaymaster));
    }

    function deployAdvancedTrading() internal {
        // Deploy LimitExecutorV2 (needs keeper and backendSigner)
        limitExecutor = new LimitExecutorV2Contract(
            address(mockUSDC),
            address(riskManager),
            address(positionManager),
            address(treasuryManager),
            keeperWallet, // keeper
            priceSignerWallet // backendSigner
        );
        console.log("  LimitExecutorV2 deployed:", address(limitExecutor));

        // Deploy TapToTradeExecutor (needs backendSigner)
        tapToTradeExecutor = new TapToTradeExecutorContract(
            address(mockUSDC),
            address(riskManager),
            address(positionManager),
            address(treasuryManager),
            priceSignerWallet // backendSigner
        );
        console.log("  TapToTradeExecutor deployed:", address(tapToTradeExecutor));

        // Deploy OneTapProfit (needs backendSigner and settler)
        oneTapProfit = new OneTapProfitContract(
            address(mockUSDC),
            address(treasuryManager),
            priceSignerWallet, // backendSigner
            keeperWallet // settler
        );
        console.log("  OneTapProfit deployed:", address(oneTapProfit));
    }

    function deployStakingContracts() internal {
        // Deploy TethraStaking
        tethraStaking = new TethraStaking(address(tethraToken), address(mockUSDC));
        console.log("  TethraStaking deployed:", address(tethraStaking));

        // Deploy LiquidityMining
        liquidityMining = new LiquidityMining(address(mockUSDC), address(tethraToken));
        console.log("  LiquidityMining deployed:", address(liquidityMining));
    }

    function setupRolesAndInitialize() internal {
        console.log("\n  === Granting Roles ===");

        // Grant EXECUTOR_ROLE on TreasuryManager to all trading executors
        bytes32 executorRole = treasuryManager.EXECUTOR_ROLE();
        treasuryManager.grantRole(executorRole, address(marketExecutor));
        console.log("Granted EXECUTOR_ROLE to MarketExecutor");

        treasuryManager.grantRole(executorRole, address(limitExecutor));
        console.log("Granted EXECUTOR_ROLE to LimitExecutorV2");

        treasuryManager.grantRole(executorRole, address(tapToTradeExecutor));
        console.log("Granted EXECUTOR_ROLE to TapToTradeExecutor");

        treasuryManager.grantRole(executorRole, address(oneTapProfit));
        console.log("Granted EXECUTOR_ROLE to OneTapProfit");

        // Grant KEEPER_ROLE on TreasuryManager to keeper wallet
        bytes32 keeperRole = treasuryManager.KEEPER_ROLE();
        treasuryManager.grantRole(keeperRole, keeperWallet);
        console.log("Granted KEEPER_ROLE to Keeper Wallet");

        // Grant KEEPER_ROLE on LimitExecutorV2 to keeper wallet
        bytes32 limitKeeperRole = limitExecutor.KEEPER_ROLE();
        limitExecutor.grantRole(limitKeeperRole, keeperWallet);
        console.log("Granted KEEPER_ROLE on LimitExecutor to Keeper Wallet");

        // Note: BACKEND_SIGNER_ROLE already granted in MarketExecutor constructor
        console.log("  [OK] BACKEND_SIGNER_ROLE granted to Price Signer (in constructor)");

        console.log("\n  === Initializing Contracts ===");

        // Update TreasuryManager with staking address
        treasuryManager.updateAddresses(address(tethraStaking), protocolTreasury);
        console.log("Updated TreasuryManager addresses");

        // Initialize TethraToken distribution
        tethraToken.initialize(
            protocolTreasury, // Treasury allocation
            teamWallet, // Team allocation
            address(tethraStaking), // Staking rewards
            address(liquidityMining) // Liquidity mining rewards
        );
        console.log("Initialized TethraToken distribution");
        console.log("    - Treasury:", protocolTreasury, "- 1M TETH");
        console.log("    - Team:", teamWallet, "- 2M TETH");
        console.log("    - Staking:", address(tethraStaking), "- 5M TETH");
        console.log("    - Liquidity Mining:", address(liquidityMining), "- 2M TETH");
    }

    function printDeploymentSummary() internal view {
        console.log("\n=================================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("=================================================");
        console.log("\nToken Contracts:");
        console.log("  MockUSDC:", address(mockUSDC));
        console.log("  TethraToken:", address(tethraToken));

        console.log("\nCore Trading:");
        console.log("  RiskManager:", address(riskManager));
        console.log("  PositionManager:", address(positionManager));
        console.log("  TreasuryManager:", address(treasuryManager));
        console.log("  MarketExecutor:", address(marketExecutor));
        console.log("  USDCPaymaster:", address(usdcPaymaster));

        console.log("\nAdvanced Trading:");
        console.log("  LimitExecutorV2:", address(limitExecutor));
        console.log("  TapToTradeExecutor:", address(tapToTradeExecutor));
        console.log("  OneTapProfit:", address(oneTapProfit));

        console.log("\nStaking & Incentives:");
        console.log("  TethraStaking:", address(tethraStaking));
        console.log("  LiquidityMining:", address(liquidityMining));

        console.log("\nRole Assignments:");
        console.log("  Keeper Wallet:", keeperWallet);
        console.log("  Price Signer:", priceSignerWallet);
        console.log("  Team Wallet:", teamWallet);
        console.log("  Protocol Treasury:", protocolTreasury);

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=================================================");
        console.log("\nNext Steps:");
        console.log("1. Copy addresses to tethra-be/.env");
        console.log("2. Fund TreasuryManager with USDC liquidity");
        console.log("3. Test market orders on frontend");
        console.log("4. Verify contracts on BaseScan");
        console.log("=================================================\n");
    }

    function saveDeployment() internal {
        string memory json = string(
            abi.encodePacked(
                "{\n",
                '  "chainId": ',
                vm.toString(block.chainid),
                ",\n",
                '  "deployer": "',
                vm.toString(deployer),
                '",\n',
                '  "timestamp": ',
                vm.toString(block.timestamp),
                ",\n",
                '  "contracts": {\n',
                '    "MockUSDC": "',
                vm.toString(address(mockUSDC)),
                '",\n',
                '    "TethraToken": "',
                vm.toString(address(tethraToken)),
                '",\n',
                '    "RiskManager": "',
                vm.toString(address(riskManager)),
                '",\n',
                '    "PositionManager": "',
                vm.toString(address(positionManager)),
                '",\n',
                '    "TreasuryManager": "',
                vm.toString(address(treasuryManager)),
                '",\n',
                '    "MarketExecutor": "',
                vm.toString(address(marketExecutor)),
                '",\n',
                '    "LimitExecutorV2": "',
                vm.toString(address(limitExecutor)),
                '",\n',
                '    "TapToTradeExecutor": "',
                vm.toString(address(tapToTradeExecutor)),
                '",\n',
                '    "OneTapProfit": "',
                vm.toString(address(oneTapProfit)),
                '",\n',
                '    "USDCPaymaster": "',
                vm.toString(address(usdcPaymaster)),
                '",\n',
                '    "TethraStaking": "',
                vm.toString(address(tethraStaking)),
                '",\n',
                '    "LiquidityMining": "',
                vm.toString(address(liquidityMining)),
                '"\n',
                "  },\n",
                '  "roles": {\n',
                '    "keeperWallet": "',
                vm.toString(keeperWallet),
                '",\n',
                '    "priceSignerWallet": "',
                vm.toString(priceSignerWallet),
                '",\n',
                '    "teamWallet": "',
                vm.toString(teamWallet),
                '",\n',
                '    "protocolTreasury": "',
                vm.toString(protocolTreasury),
                '"\n',
                "  }\n",
                "}"
            )
        );

        // Create deployments directory if it doesn't exist
        string memory network =
            block.chainid == 84532 ? "base-sepolia" : block.chainid == 8453 ? "base-mainnet" : "unknown";

        string memory filepath = string(abi.encodePacked("deployments/", network, "-latest.json"));
        vm.writeFile(filepath, json);

        console.log("Deployment saved to:", filepath);
    }
}

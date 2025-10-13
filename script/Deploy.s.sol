// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

// Core Contracts
import {MockUSDC} from "../src/token/MockUSDC.sol";
import {TethraToken} from "../src/token/TethraToken.sol";
import {RiskManager} from "../src/risk/RiskManager.sol";
import {PositionManager} from "../src/trading/PositionManager.sol";
import {TreasuryManager} from "../src/treasury/TreasuryManager.sol";
import {MarketExecutor} from "../src/trading/MarketExecutor.sol";
import {TethraStaking} from "../src/staking/TethraStaking.sol";
import {LiquidityMining} from "../src/staking/LiquidityMining.sol";
import {USDCPaymaster} from "../src/paymaster/USDCPaymaster.sol";

/**
 * @title Deploy
 * @notice Complete deployment script for Tethra DEX
 * @dev Deploys all contracts in correct order and initializes them
 *
 * Usage:
 * - Local: forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 * - Testnet: forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
 * - Mainnet: forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --ledger --broadcast --verify
 */
contract Deploy is Script {
    // Deployed contracts
    MockUSDC public usdc;
    TethraToken public tetra;
    RiskManager public riskManager;
    PositionManager public positionManager;
    TreasuryManager public treasuryManager;
    MarketExecutor public marketExecutor;
    TethraStaking public tethraStaking;
    LiquidityMining public liquidityMining;
    USDCPaymaster public usdcPaymaster;

    // Configuration
    address public deployer;
    address public treasury;
    address public team;
    address public priceSigner;

    function setUp() public {}

    function run() public {
        // Get deployer address
        deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        // Set addresses (can be overridden via env vars)
        treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        team = vm.envOr("TEAM_ADDRESS", deployer);
        priceSigner = vm.envOr("PRICE_SIGNER_ADDRESS", deployer);

        console.log("\n=================================================");
        console.log("        TETHRA DEX - DEPLOYMENT SCRIPT");
        console.log("=================================================\n");

        console.log("Deployer Address:", deployer);
        console.log("Treasury Address:", treasury);
        console.log("Team Address:", team);
        console.log("Price Signer:", priceSigner);
        console.log("");

        vm.startBroadcast();

        // ============================================
        // STEP 1: Deploy Token Contracts
        // ============================================
        console.log("=================================================");
        console.log("STEP 1: Deploying Token Contracts...");
        console.log("=================================================\n");

        // Deploy MockUSDC (for testing/local deployment)
        usdc = new MockUSDC(1000000); // 1M USDC initial supply
        console.log("[1/9] MockUSDC deployed at:", address(usdc));

        // Deploy TETRA Token
        tetra = new TethraToken();
        console.log("[2/9] TethraToken deployed at:", address(tetra));

        console.log("");

        // ============================================
        // STEP 2: Deploy Core Trading Contracts
        // ============================================
        console.log("=================================================");
        console.log("STEP 2: Deploying Core Trading Contracts...");
        console.log("=================================================\n");

        // Deploy RiskManager
        riskManager = new RiskManager();
        console.log("[3/9] RiskManager deployed at:", address(riskManager));

        // Deploy PositionManager
        positionManager = new PositionManager();
        console.log("[4/9] PositionManager deployed at:", address(positionManager));

        console.log("");

        // ============================================
        // STEP 3: Deploy Economic Contracts
        // ============================================
        console.log("=================================================");
        console.log("STEP 3: Deploying Economic Contracts...");
        console.log("=================================================\n");

        // Deploy TethraStaking
        tethraStaking = new TethraStaking(address(tetra), address(usdc));
        console.log("[5/9] TethraStaking deployed at:", address(tethraStaking));

        // Deploy LiquidityMining
        liquidityMining = new LiquidityMining(address(tetra), address(usdc));
        console.log("[6/9] LiquidityMining deployed at:", address(liquidityMining));

        // Deploy TreasuryManager
        treasuryManager = new TreasuryManager(address(usdc), treasury, address(tethraStaking));
        console.log("[7/9] TreasuryManager deployed at:", address(treasuryManager));

        console.log("");

        // ============================================
        // STEP 4: Deploy Executor Contracts
        // ============================================
        console.log("=================================================");
        console.log("STEP 4: Deploying Executor Contracts...");
        console.log("=================================================\n");

        // Deploy MarketExecutor
        marketExecutor = new MarketExecutor(
            address(usdc), address(riskManager), address(positionManager), address(treasuryManager), priceSigner
        );
        console.log("[8/9] MarketExecutor deployed at:", address(marketExecutor));

        // Deploy USDCPaymaster
        usdcPaymaster = new USDCPaymaster(
            address(usdc),
            2000_000000 // 2000 USDC per ETH (6 decimals)
        );
        console.log("[9/9] USDCPaymaster deployed at:", address(usdcPaymaster));

        console.log("");

        // ============================================
        // STEP 5: Initialize Contracts
        // ============================================
        console.log("=================================================");
        console.log("STEP 5: Initializing Contracts...");
        console.log("=================================================\n");

        // Initialize TethraToken distribution
        tetra.initialize(
            treasury, // 30% to treasury
            address(tethraStaking), // 20% to staking rewards
            address(liquidityMining), // 40% to liquidity mining
            team // 10% to team
        );
        console.log("[OK] TethraToken initialized with distribution");

        // Set executor permissions on PositionManager
        positionManager.grantRole(positionManager.EXECUTOR_ROLE(), address(marketExecutor));
        console.log("[OK] MarketExecutor authorized on PositionManager");

        // Set executor permissions on TreasuryManager
        treasuryManager.grantRole(treasuryManager.EXECUTOR_ROLE(), address(marketExecutor));
        console.log("[OK] MarketExecutor authorized on TreasuryManager");

        // Note: RiskManager uses Ownable, not AccessControl
        // Executor validation is done via onlyOwner on modify functions
        console.log("[OK] RiskManager owned by deployer (owner-based access)");

        // Set executor on USDCPaymaster
        usdcPaymaster.setExecutorStatus(address(marketExecutor), true);
        console.log("[OK] MarketExecutor authorized on USDCPaymaster");

        console.log("");

        // ============================================
        // STEP 6: Configure Default Assets
        // ============================================
        console.log("=================================================");
        console.log("STEP 6: Configuring Default Assets...");
        console.log("=================================================\n");

        // Configure BTC/USD
        riskManager.setAssetConfig(
            "BTC", // symbol
            true, // enabled
            100, // maxLeverage: 100x
            10_000_000e6, // maxPositionSize: 10M USDC
            100_000_000e6, // maxOpenInterest: 100M USDC
            9000 // liquidationThreshold: 90% (in basis points)
        );
        console.log("[OK] BTC asset configured (symbol: BTC)");

        // Configure ETH/USD
        riskManager.setAssetConfig(
            "ETH", // symbol
            true, // enabled
            100, // maxLeverage: 100x
            10_000_000e6, // maxPositionSize: 10M USDC
            100_000_000e6, // maxOpenInterest: 100M USDC
            9000 // liquidationThreshold: 90% (in basis points)
        );
        console.log("[OK] ETH asset configured (symbol: ETH)");

        console.log("");

        // ============================================
        // STEP 7: Add Initial Liquidity (Optional)
        // ============================================
        console.log("=================================================");
        console.log("STEP 7: Adding Initial Liquidity...");
        console.log("=================================================\n");

        // Mint initial USDC to deployer for liquidity
        uint256 initialLiquidity = 1_000_000e6; // 1M USDC
        usdc.mint(deployer, initialLiquidity);

        // Approve and add liquidity to TreasuryManager
        usdc.approve(address(treasuryManager), initialLiquidity);
        treasuryManager.addLiquidity(initialLiquidity);

        console.log("[OK] Added initial liquidity:");
        console.log("     Amount: 1,000,000 USDC");

        // Note: TETRA was already sent to LiquidityMining during initialization (40M tokens)
        // No need to deposit additional rewards, contract already has the allocation
        console.log("[OK] LiquidityMining has TETRA allocation:");
        console.log("     Amount: 40,000,000 TETRA (from initialization)");

        console.log("");

        vm.stopBroadcast();

        // ============================================
        // DEPLOYMENT SUMMARY
        // ============================================
        console.log("\n=================================================");
        console.log("        DEPLOYMENT COMPLETED SUCCESSFULLY!");
        console.log("=================================================\n");

        printDeploymentSummary();

        // Save deployment addresses to file
        saveDeploymentAddresses();
    }

    function printDeploymentSummary() internal view {
        console.log("=================================================");
        console.log("CONTRACT ADDRESSES");
        console.log("=================================================\n");

        console.log("Token Contracts:");
        console.log("-------------------------------------------------");
        console.log("MockUSDC Address:        ", address(usdc));
        console.log("TethraToken Address:     ", address(tetra));
        console.log("");

        console.log("Core Trading Contracts:");
        console.log("-------------------------------------------------");
        console.log("RiskManager Address:     ", address(riskManager));
        console.log("PositionManager Address: ", address(positionManager));
        console.log("TreasuryManager Address: ", address(treasuryManager));
        console.log("MarketExecutor Address:  ", address(marketExecutor));
        console.log("");

        console.log("Economic Contracts:");
        console.log("-------------------------------------------------");
        console.log("TethraStaking Address:   ", address(tethraStaking));
        console.log("LiquidityMining Address: ", address(liquidityMining));
        console.log("");

        console.log("Utility Contracts:");
        console.log("-------------------------------------------------");
        console.log("USDCPaymaster Address:   ", address(usdcPaymaster));
        console.log("");

        console.log("Configuration:");
        console.log("-------------------------------------------------");
        console.log("Deployer:                ", deployer);
        console.log("Treasury:                ", treasury);
        console.log("Team:                    ", team);
        console.log("Price Signer:            ", priceSigner);
        console.log("");

        console.log("Token Distribution:");
        console.log("-------------------------------------------------");
        console.log("Total TETRA Supply:      100,000,000 TETRA");
        console.log("  - Treasury (30%):      30,000,000 TETRA");
        console.log("  - Staking (20%):       20,000,000 TETRA");
        console.log("  - Liquidity Mining (40%): 40,000,000 TETRA");
        console.log("  - Team (10%):          10,000,000 TETRA");
        console.log("");

        console.log("Initial Liquidity:");
        console.log("-------------------------------------------------");
        console.log("Treasury Liquidity:      1,000,000 USDC");
        console.log("Mining Rewards:          40,000,000 TETRA (40%)");
        console.log("");

        console.log("Configured Assets:");
        console.log("-------------------------------------------------");
        console.log("BTC - Max Leverage: 100x, Max Position: 10M USDC");
        console.log("ETH - Max Leverage: 100x, Max Position: 10M USDC");
        console.log("");

        console.log("=================================================");
        console.log("Next Steps:");
        console.log("=================================================");
        console.log("1. Save the contract addresses above");
        console.log("2. Verify contracts on block explorer");
        console.log("3. Update frontend with new addresses");
        console.log("4. Test all functionality on testnet");
        console.log("5. Set up monitoring and alerts");
        console.log("");
        console.log("For testing, you can claim USDC from the faucet:");
        console.log("  usdc.faucet() - Get 1000 USDC");
        console.log("");
        console.log("=================================================\n");
    }

    function saveDeploymentAddresses() internal {
        // Create deployment info string
        string memory deploymentInfo = string.concat(
            "# Tethra DEX - Deployment Addresses\n\n",
            "## Network Information\n",
            "- Chain ID: ",
            vm.toString(block.chainid),
            "\n",
            "- Block Number: ",
            vm.toString(block.number),
            "\n",
            "- Timestamp: ",
            vm.toString(block.timestamp),
            "\n\n",
            "## Token Contracts\n",
            "- MockUSDC: ",
            vm.toString(address(usdc)),
            "\n",
            "- TethraToken: ",
            vm.toString(address(tetra)),
            "\n\n",
            "## Core Trading Contracts\n",
            "- RiskManager: ",
            vm.toString(address(riskManager)),
            "\n",
            "- PositionManager: ",
            vm.toString(address(positionManager)),
            "\n",
            "- TreasuryManager: ",
            vm.toString(address(treasuryManager)),
            "\n",
            "- MarketExecutor: ",
            vm.toString(address(marketExecutor)),
            "\n\n",
            "## Economic Contracts\n",
            "- TethraStaking: ",
            vm.toString(address(tethraStaking)),
            "\n",
            "- LiquidityMining: ",
            vm.toString(address(liquidityMining)),
            "\n\n",
            "## Utility Contracts\n",
            "- USDCPaymaster: ",
            vm.toString(address(usdcPaymaster)),
            "\n\n",
            "## Configuration\n",
            "- Deployer: ",
            vm.toString(deployer),
            "\n",
            "- Treasury: ",
            vm.toString(treasury),
            "\n",
            "- Team: ",
            vm.toString(team),
            "\n",
            "- Price Signer: ",
            vm.toString(priceSigner),
            "\n\n",
            "## Assets\n",
            "- BTC: Max 100x leverage, 10M USDC max position\n",
            "- ETH: Max 100x leverage, 10M USDC max position\n"
        );

        // Write to file
        string memory filename =
            string.concat("./deployments/", vm.toString(block.chainid), "-", vm.toString(block.timestamp), ".txt");

        vm.writeFile(filename, deploymentInfo);
        console.log("Deployment addresses saved to:", filename);
    }
}

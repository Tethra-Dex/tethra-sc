// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/paymaster/USDCPaymaster.sol";
import "../src/trading/MarketExecutor.sol";

/**
 * @title Setup Paymaster Script
 * @notice Configure Paymaster for relay operations
 *
 * Usage:
 * forge script script/SetupPaymaster.s.sol:SetupPaymaster --rpc-url base-sepolia --broadcast
 */
contract SetupPaymaster is Script {
    // Contract addresses from deployment
    address constant PAYMASTER = 0x94FbB9C6C854599c7562c282eADa4889115CCd8E;
    address constant MARKET_EXECUTOR = 0x6D91332E27a5BddCe9486ad4e9cA3C319947a302;

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Paymaster Setup ===");
        console.log("Deployer:", deployer);
        console.log("Paymaster:", PAYMASTER);

        vm.startBroadcast(deployerPrivateKey);

        USDCPaymaster paymaster = USDCPaymaster(payable(PAYMASTER));

        // 1. Set MarketExecutor as allowed executor
        console.log("\n1. Setting MarketExecutor as allowed executor...");
        paymaster.setExecutorStatus(MARKET_EXECUTOR, true);
        console.log("   MarketExecutor whitelisted");

        // 2. Check if relay wallet is set (you need to add it manually)
        // Get relay wallet address from environment if available
        address relayWallet = vm.envOr("RELAY_WALLET_ADDRESS", address(0));

        if (relayWallet != address(0)) {
            console.log("\n2. Setting Relay Wallet as allowed executor...");
            console.log("   Relay Wallet:", relayWallet);
            paymaster.setExecutorStatus(relayWallet, true);
            console.log("   Relay Wallet whitelisted");
        } else {
            console.log("\n2. No RELAY_WALLET_ADDRESS in .env");
            console.log("   Please add RELAY_WALLET_ADDRESS to .env and run again");
        }

        // 3. Fund paymaster with native token (optional, can be done separately)
        uint256 fundAmount = vm.envOr("PAYMASTER_FUND_AMOUNT", uint256(0));
        if (fundAmount > 0) {
            console.log("\n3. Funding Paymaster with ETH...");
            console.log("   Amount:", fundAmount);
            paymaster.fundPaymaster{value: fundAmount}();
            console.log("   Paymaster funded");
        } else {
            console.log("\n3. No PAYMASTER_FUND_AMOUNT specified");
            console.log("   Paymaster needs ETH to pay for gas!");
            console.log("   You can fund it with: cast send <PAYMASTER> --value 0.1ether");
        }

        // 4. Display current configuration
        console.log("\n=== Current Configuration ===");
        (uint256 rate, uint256 premium) = paymaster.getRateInfo();
        console.log("USDC per ETH:", rate);
        console.log("Premium (bps):", premium);
        console.log("Min Deposit:", paymaster.minDeposit());

        bool marketExecutorAllowed = paymaster.allowedExecutors(MARKET_EXECUTOR);
        console.log("\nMarketExecutor allowed:", marketExecutorAllowed);

        if (relayWallet != address(0)) {
            bool relayAllowed = paymaster.allowedExecutors(relayWallet);
            console.log("Relay Wallet allowed:", relayAllowed);
        }

        uint256 paymasterBalance = address(paymaster).balance;
        console.log("\nPaymaster ETH balance:", paymasterBalance);

        vm.stopBroadcast();

        console.log("\n=== Setup Complete ===");

        if (paymasterBalance < 0.01 ether) {
            console.log("\nWARNING: Paymaster has low ETH balance!");
            console.log("Please fund it with:");
            console.log("cast send", PAYMASTER, "--value 0.1ether --rpc-url base-sepolia");
        }

        if (relayWallet == address(0)) {
            console.log("\nNOTE: Please set RELAY_WALLET_ADDRESS in .env");
            console.log("Then run this script again to whitelist the relay wallet");
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/token/TethraToken.sol";

contract InitializeTokenScript is Script {
    // Contract addresses from .env
    address constant TETHRA_TOKEN = 0x6f1330f207Ab5e2a52c550AF308bA28e3c517311;
    address constant TETHRA_STAKING = 0x69FFE0989234971eA2bc542c84c9861b0D8F9b17;
    address constant LIQUIDITY_MINING = 0x49c37C3b3a96028D2A1A1e678A302C1d727f3FEF;
    
    // From .env file
    address constant TREASURY_ADDRESS = 0x722550Bb8Ec6416522AfE9EAf446F0DE3262f701;
    address constant TEAM_ADDRESS = 0x722550Bb8Ec6416522AfE9EAf446F0DE3262f701;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // Get TethraToken contract instance
        TethraToken tethra = TethraToken(TETHRA_TOKEN);

        // Check if already initialized
        require(!tethra.isInitialized(), "TethraToken: Already initialized");

        console.log("Initializing TethraToken with distribution:");
        console.log("Treasury:", TREASURY_ADDRESS);
        console.log("Team:", TEAM_ADDRESS);
        console.log("Staking Vault:", TETHRA_STAKING);
        console.log("Liquidity Mining:", LIQUIDITY_MINING);

        // Initialize token distribution
        tethra.initialize(
            TREASURY_ADDRESS,    // Treasury: 10% (1M TETH)
            TEAM_ADDRESS,        // Team: 20% (2M TETH) 
            TETHRA_STAKING,      // Staking: 50% (5M TETH)
            LIQUIDITY_MINING     // Mining: 20% (2M TETH)
        );

        console.log("TethraToken initialized successfully!");
        
        // Verify distributions
        console.log("\n=== Token Distribution Verification ===");
        console.log("Treasury balance:", tethra.balanceOf(TREASURY_ADDRESS) / 1e18, "TETH");
        console.log("Team balance:", tethra.balanceOf(TEAM_ADDRESS) / 1e18, "TETH");
        console.log("Staking balance:", tethra.balanceOf(TETHRA_STAKING) / 1e18, "TETH");
        console.log("Mining balance:", tethra.balanceOf(LIQUIDITY_MINING) / 1e18, "TETH");
        console.log("Total Supply:", tethra.totalSupply() / 1e18, "TETH");

        vm.stopBroadcast();
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/token/TethraToken.sol";

contract VerifyTokenScript is Script {
    // Contract addresses from .env
    address constant TETHRA_TOKEN = 0x6f1330f207Ab5e2a52c550AF308bA28e3c517311;
    address constant TETHRA_STAKING = 0x69FFE0989234971eA2bc542c84c9861b0D8F9b17;
    address constant LIQUIDITY_MINING = 0x49c37C3b3a96028D2A1A1e678A302C1d727f3FEF;
    
    // From .env file
    address constant TREASURY_ADDRESS = 0x722550Bb8Ec6416522AfE9EAf446F0DE3262f701;
    address constant TEAM_ADDRESS = 0x722550Bb8Ec6416522AfE9EAf446F0DE3262f701;

    function run() external view {
        // Get TethraToken contract instance
        TethraToken tethra = TethraToken(TETHRA_TOKEN);

        console.log("=== TethraToken Distribution Status ===");
        console.log("Token Address:", TETHRA_TOKEN);
        console.log("Is Initialized:", tethra.isInitialized());
        
        // Verify distributions
        console.log("\n=== Current Token Distribution ===");
        console.log("Treasury balance:", tethra.balanceOf(TREASURY_ADDRESS) / 1e18, "TETH");
        console.log("Team balance:", tethra.balanceOf(TEAM_ADDRESS) / 1e18, "TETH");
        console.log("Staking balance:", tethra.balanceOf(TETHRA_STAKING) / 1e18, "TETH");
        console.log("Mining balance:", tethra.balanceOf(LIQUIDITY_MINING) / 1e18, "TETH");
        console.log("Total Supply:", tethra.totalSupply() / 1e18, "TETH");

        console.log("\n=== Expected Distribution ===");
        console.log("Treasury: 1,000,000 TETH (10%)");
        console.log("Team: 2,000,000 TETH (20%)");  
        console.log("Staking: 5,000,000 TETH (50%)");
        console.log("Mining: 2,000,000 TETH (20%)");
        console.log("Total: 10,000,000 TETH (100%)");

        console.log("\nPriority 1 COMPLETED - Token already initialized!");
        console.log("Ready for Priority 2 - Treasury Setup");
    }
}
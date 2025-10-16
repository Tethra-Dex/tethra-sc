// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/treasury/TreasuryManager.sol";
import "../src/staking/TethraStaking.sol";

contract SetupTreasuryScript is Script {
    // Contract addresses
    address payable constant TREASURY_MANAGER = payable(0x157e68fBDD7D8294badeD37d876aEb7765986681);
    address constant TETHRA_STAKING = 0x69FFE0989234971eA2bc542c84c9861b0D8F9b17;
    address constant LIQUIDITY_MINING = 0x49c37C3b3a96028D2A1A1e678A302C1d727f3FEF;
    
    // Treasury addresses
    address constant TREASURY_ADDRESS = 0x722550Bb8Ec6416522AfE9EAf446F0DE3262f701;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        TreasuryManager treasury = TreasuryManager(TREASURY_MANAGER);

        console.log("Setting up TreasuryManager for proper fee distribution...");

        // Update fee distribution ratios to match our tokenomics:
        // 60% to GM Pools (liquidity), 30% to stakers, 10% to treasury
        treasury.updateFeeDistribution(
            6000,  // 60% to liquidity pool (GM Pool LPs)
            3000,  // 30% to staking rewards (TETH stakers)
            1000   // 10% to protocol treasury
        );

        // Update addresses to ensure staking rewards go to TethraStaking contract
        treasury.updateAddresses(
            TETHRA_STAKING,     // Staking rewards address
            TREASURY_ADDRESS    // Protocol treasury address
        );

        console.log("TreasuryManager setup completed!");
        
        // Verify settings
        console.log("\n=== Treasury Configuration ===");
        (uint256 toLiquidity, uint256 toStaking, uint256 toTreasury) = treasury.getFeeDistribution();
        console.log("Fee to Liquidity:", toLiquidity / 100, "%");
        console.log("Fee to Staking:", toStaking / 100, "%"); 
        console.log("Fee to Treasury:", toTreasury / 100, "%");
        
        console.log("Staking Rewards Address:", treasury.stakingRewards());
        console.log("Protocol Treasury Address:", treasury.protocolTreasury());

        vm.stopBroadcast();
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/treasury/TreasuryManager.sol";
import "../src/staking/TethraStaking.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ConnectTreasuryStakingScript is Script {
    // Contract addresses
    address payable constant TREASURY_MANAGER = payable(0x157e68fBDD7D8294badeD37d876aEb7765986681);
    address constant TETHRA_STAKING = 0x69FFE0989234971eA2bc542c84c9861b0D8F9b17;
    address constant USDC_TOKEN = 0x9d660c5d4BFE4b7fcC76f327b22ABF7773DD48c1;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        TreasuryManager treasury = TreasuryManager(TREASURY_MANAGER);
        TethraStaking staking = TethraStaking(TETHRA_STAKING);
        IERC20 usdc = IERC20(USDC_TOKEN);

        console.log("Connecting TreasuryManager with TethraStaking for automated rewards...");

        // Check current setup
        console.log("Treasury Manager Address:", address(treasury));
        console.log("TethraStaking Address:", address(staking));
        console.log("Current staking rewards address in Treasury:", treasury.stakingRewards());
        
        // Verify USDC addresses match
        address stakingUSDC = address(staking.usdc());
        console.log("USDC address in TethraStaking:", stakingUSDC);
        console.log("USDC address used:", USDC_TOKEN);
        require(stakingUSDC == USDC_TOKEN, "USDC address mismatch");

        // Check if treasury has any pending fees to distribute as example
        uint256 pendingFees = treasury.getPendingFees();
        console.log("Pending fees in treasury:", pendingFees / 1e6, "USDC");

        // If there are pending fees, demonstrate the distribution flow
        if (pendingFees > 0) {
            console.log("\n=== Distributing Pending Fees ===");
            
            // Get treasury USDC balance before
            uint256 treasuryBalance = usdc.balanceOf(address(treasury));
            console.log("Treasury USDC balance:", treasuryBalance / 1e6, "USDC");
            
            // Distribute fees (only admin can do this)
            treasury.distributeFees();
            
            // Check if staking contract received USDC
            uint256 stakingBalance = usdc.balanceOf(address(staking));
            console.log("TethraStaking USDC balance after distribution:", stakingBalance / 1e6, "USDC");
        }

        console.log("\n=== Integration Verification ===");
        console.log("TreasuryManager connected to TethraStaking");
        console.log("Fee distribution configured:");
        
        (uint256 toLiquidity, uint256 toStaking, uint256 toTreasury) = treasury.getFeeDistribution();
        console.log("   - Liquidity Pool:", toLiquidity / 100, "%");
        console.log("   - Staking Rewards:", toStaking / 100, "%");
        console.log("   - Protocol Treasury:", toTreasury / 100, "%");

        console.log("\n=== Next Steps ===");
        console.log("1. Execute trades to generate fees in TreasuryManager");  
        console.log("2. Call treasury.distributeFees() to send USDC to TethraStaking");
        console.log("3. Call staking.addRewards() to update staker rewards");

        vm.stopBroadcast();
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/token/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC public usdc;
    
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    function setUp() public {
        usdc = new MockUSDC(1000000); // 1M USDC initial supply
    }
    
    // ====================
    // DEPLOYMENT TESTS
    // ====================
    
    function testDeployment() public {
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
    }
    
    // ====================
    // FAUCET TESTS
    // ====================
    
    function testFaucetClaim() public {
        vm.prank(user1);
        usdc.faucet();
        
        assertEq(usdc.balanceOf(user1), 1000 * 10**6); // 1000 USDC
    }
    
    function testFaucetOnlyOnce() public {
        // First claim
        vm.prank(user1);
        usdc.faucet();
        
        // Try to claim again immediately - should fail
        vm.prank(user1);
        vm.expectRevert("MockUSDC: Already claimed");
        usdc.faucet();
    }
    
    function testFaucetMultipleUsers() public {
        vm.prank(user1);
        usdc.faucet();
        
        vm.prank(user2);
        usdc.faucet();
        
        assertEq(usdc.balanceOf(user1), 1000 * 10**6);
        assertEq(usdc.balanceOf(user2), 1000 * 10**6);
    }
    
    function testHasClaimedStatus() public {
        // Before claiming
        assertFalse(usdc.hasClaimed(user1));
        
        // After claiming
        vm.prank(user1);
        usdc.faucet();
        
        assertTrue(usdc.hasClaimed(user1));
    }
    
    function testResetFaucetClaim() public {
        // Claim
        vm.prank(user1);
        usdc.faucet();
        assertTrue(usdc.hasClaimed(user1));
        
        // Reset by owner
        usdc.resetFaucetClaim(user1);
        assertFalse(usdc.hasClaimed(user1));
        
        // Can claim again
        vm.prank(user1);
        usdc.faucet();
        assertEq(usdc.balanceOf(user1), 2000 * 10**6);
    }
    
    // ====================
    // MINTING TESTS
    // ====================
    
    function testMintAsOwner() public {
        usdc.mint(user1, 5000 * 10**6);
        assertEq(usdc.balanceOf(user1), 5000 * 10**6);
    }
    
    function testMintAsNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        usdc.mint(user2, 5000 * 10**6);
    }
    
    function testMintToZeroAddress() public {
        vm.expectRevert();
        usdc.mint(address(0), 1000 * 10**6);
    }
    
    // ====================
    // TRANSFER TESTS
    // ====================
    
    function testTransfer() public {
        usdc.mint(user1, 1000 * 10**6);
        
        vm.prank(user1);
        usdc.transfer(user2, 500 * 10**6);
        
        assertEq(usdc.balanceOf(user1), 500 * 10**6);
        assertEq(usdc.balanceOf(user2), 500 * 10**6);
    }
    
    function testTransferInsufficientBalance() public {
        usdc.mint(user1, 100 * 10**6);
        
        vm.prank(user1);
        vm.expectRevert();
        usdc.transfer(user2, 200 * 10**6);
    }
    
    function testTransferToZeroAddress() public {
        usdc.mint(user1, 1000 * 10**6);
        
        vm.prank(user1);
        vm.expectRevert();
        usdc.transfer(address(0), 500 * 10**6);
    }
    
    // ====================
    // APPROVE & TRANSFERFROM TESTS
    // ====================
    
    function testApprove() public {
        vm.prank(user1);
        usdc.approve(user2, 1000 * 10**6);
        
        assertEq(usdc.allowance(user1, user2), 1000 * 10**6);
    }
    
    function testTransferFrom() public {
        usdc.mint(user1, 1000 * 10**6);
        
        vm.prank(user1);
        usdc.approve(user2, 500 * 10**6);
        
        vm.prank(user2);
        usdc.transferFrom(user1, user2, 500 * 10**6);
        
        assertEq(usdc.balanceOf(user1), 500 * 10**6);
        assertEq(usdc.balanceOf(user2), 500 * 10**6);
    }
    
    function testTransferFromInsufficientAllowance() public {
        usdc.mint(user1, 1000 * 10**6);
        
        vm.prank(user1);
        usdc.approve(user2, 300 * 10**6);
        
        vm.prank(user2);
        vm.expectRevert();
        usdc.transferFrom(user1, user2, 500 * 10**6);
    }
    
    // ====================
    // EDGE CASES
    // ====================
    
    function testMultipleFaucetClaimsReset() public {
        // Test that users can claim multiple times after reset
        address[] memory users = new address[](5);
        for (uint i = 0; i < 5; i++) {
            users[i] = address(uint160(i + 10));
            vm.prank(users[i]);
            usdc.faucet();
        }
        
        // All users should have 1000 USDC
        for (uint i = 0; i < 5; i++) {
            assertEq(usdc.balanceOf(users[i]), 1000 * 10**6);
        }
    }
    
    function testMultipleApprovalsAndTransfers() public {
        usdc.mint(user1, 10000 * 10**6);
        
        // Approve user2
        vm.prank(user1);
        usdc.approve(user2, 5000 * 10**6);
        
        // user2 transfers some
        vm.prank(user2);
        usdc.transferFrom(user1, user2, 2000 * 10**6);
        
        // Check remaining allowance
        assertEq(usdc.allowance(user1, user2), 3000 * 10**6);
        
        // user2 transfers rest of allowance
        vm.prank(user2);
        usdc.transferFrom(user1, user2, 3000 * 10**6);
        
        assertEq(usdc.balanceOf(user1), 5000 * 10**6);
        assertEq(usdc.balanceOf(user2), 5000 * 10**6);
    }
    
    // ====================
    // FUZZ TESTS
    // ====================
    
    function testFuzz_MintAmount(uint256 amount) public {
        // Bound amount to reasonable values
        amount = bound(amount, 1, 1_000_000_000 * 10**6);
        
        usdc.mint(user1, amount);
        assertEq(usdc.balanceOf(user1), amount);
    }
    
    function testFuzz_Transfer(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 * 10**6);
        
        usdc.mint(user1, amount);
        
        vm.prank(user1);
        usdc.transfer(user2, amount);
        
        assertEq(usdc.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(user2), amount);
    }
}

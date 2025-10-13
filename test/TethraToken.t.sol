// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/token/TethraToken.sol";

contract TethraTokenTest is Test {
    TethraToken public tetra;

    address public liquidityMining = address(0x1);
    address public stakingRewards = address(0x2);
    address public team = address(0x3);
    address public treasury = address(0x4);
    address public user = address(0x5);

    uint256 constant TOTAL_SUPPLY = 10_000_000 * 10 ** 18;

    function setUp() public {
        tetra = new TethraToken();

        // Initialize token distribution
        tetra.initialize(treasury, team, stakingRewards, liquidityMining);
    }

    // ====================
    // DEPLOYMENT TESTS
    // ====================

    function testDeployment() public {
        assertEq(tetra.name(), "Tethra Token");
        assertEq(tetra.symbol(), "TETH");
        assertEq(tetra.decimals(), 18);
        assertEq(tetra.totalSupply(), TOTAL_SUPPLY);
    }

    function testInitialDistribution() public {
        // Check total supply
        assertEq(tetra.totalSupply(), TOTAL_SUPPLY);

        // Check individual allocations
        // 20% to Liquidity Mining
        assertEq(tetra.balanceOf(liquidityMining), TOTAL_SUPPLY * 20 / 100);

        // 50% to Staking Rewards
        assertEq(tetra.balanceOf(stakingRewards), TOTAL_SUPPLY * 50 / 100);

        // 20% to Team
        assertEq(tetra.balanceOf(team), TOTAL_SUPPLY * 20 / 100);

        // 10% to Treasury
        assertEq(tetra.balanceOf(treasury), TOTAL_SUPPLY * 10 / 100);
    }

    function testDistributionSum() public {
        uint256 sumOfBalances = tetra.balanceOf(liquidityMining) + tetra.balanceOf(stakingRewards)
            + tetra.balanceOf(team) + tetra.balanceOf(treasury);

        assertEq(sumOfBalances, TOTAL_SUPPLY);
    }

    function testInitializeOnlyOnce() public {
        TethraToken newToken = new TethraToken();
        newToken.initialize(treasury, team, stakingRewards, liquidityMining);

        // Try to initialize again
        vm.expectRevert("TethraToken: Already initialized");
        newToken.initialize(treasury, team, stakingRewards, liquidityMining);
    }

    function testZeroAddressRejection() public {
        TethraToken newToken = new TethraToken();

        vm.expectRevert("TethraToken: Invalid treasury");
        newToken.initialize(address(0), team, stakingRewards, liquidityMining);

        newToken = new TethraToken();
        vm.expectRevert("TethraToken: Invalid team");
        newToken.initialize(treasury, address(0), stakingRewards, liquidityMining);

        newToken = new TethraToken();
        vm.expectRevert("TethraToken: Invalid staking vault");
        newToken.initialize(treasury, team, address(0), liquidityMining);

        newToken = new TethraToken();
        vm.expectRevert("TethraToken: Invalid liquidity mining");
        newToken.initialize(treasury, team, stakingRewards, address(0));
    }

    // ====================
    // TRANSFER TESTS
    // ====================

    function testTransferFromLiquidityMining() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.prank(liquidityMining);
        tetra.transfer(user, amount);

        assertEq(tetra.balanceOf(user), amount);
        assertEq(tetra.balanceOf(liquidityMining), TOTAL_SUPPLY * 20 / 100 - amount);
    }

    function testTransferFromStakingRewards() public {
        uint256 amount = 500 * 10 ** 18;

        vm.prank(stakingRewards);
        tetra.transfer(user, amount);

        assertEq(tetra.balanceOf(user), amount);
    }

    function testTransferFromTeam() public {
        uint256 amount = 200 * 10 ** 18;

        vm.prank(team);
        tetra.transfer(user, amount);

        assertEq(tetra.balanceOf(user), amount);
    }

    function testTransferFromTreasury() public {
        uint256 amount = 100 * 10 ** 18;

        vm.prank(treasury);
        tetra.transfer(user, amount);

        assertEq(tetra.balanceOf(user), amount);
    }

    function testTransferInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert();
        tetra.transfer(liquidityMining, 1 * 10 ** 18);
    }

    function testTransferToZeroAddress() public {
        vm.prank(liquidityMining);
        vm.expectRevert();
        tetra.transfer(address(0), 1000 * 10 ** 18);
    }

    function testTransferBetweenUsers() public {
        // Give user some tokens first
        vm.prank(liquidityMining);
        tetra.transfer(user, 1000 * 10 ** 18);

        address user2 = address(0x6);

        vm.prank(user);
        tetra.transfer(user2, 500 * 10 ** 18);

        assertEq(tetra.balanceOf(user), 500 * 10 ** 18);
        assertEq(tetra.balanceOf(user2), 500 * 10 ** 18);
    }

    // ====================
    // APPROVE & TRANSFERFROM TESTS
    // ====================

    function testApprove() public {
        vm.prank(liquidityMining);
        tetra.approve(user, 5000 * 10 ** 18);

        assertEq(tetra.allowance(liquidityMining, user), 5000 * 10 ** 18);
    }

    function testTransferFrom() public {
        uint256 amount = 2000 * 10 ** 18;

        vm.prank(liquidityMining);
        tetra.approve(user, amount);

        vm.prank(user);
        tetra.transferFrom(liquidityMining, user, amount);

        assertEq(tetra.balanceOf(user), amount);
    }

    function testTransferFromInsufficientAllowance() public {
        vm.prank(liquidityMining);
        tetra.approve(user, 1000 * 10 ** 18);

        vm.prank(user);
        vm.expectRevert();
        tetra.transferFrom(liquidityMining, user, 2000 * 10 ** 18);
    }

    function testInfiniteApproval() public {
        vm.prank(liquidityMining);
        tetra.approve(user, type(uint256).max);

        // Transfer multiple times
        vm.prank(user);
        tetra.transferFrom(liquidityMining, user, 1000 * 10 ** 18);

        vm.prank(user);
        tetra.transferFrom(liquidityMining, user, 1000 * 10 ** 18);

        // Allowance should still be max (infinite approval)
        assertEq(tetra.allowance(liquidityMining, user), type(uint256).max);
    }

    // ====================
    // ALLOCATION MATH TESTS
    // ====================

    function testExactDistributionAmounts() public {
        // Liquidity Mining: 2,000,000 TETH (20%)
        assertEq(tetra.balanceOf(liquidityMining), 2_000_000 * 10 ** 18);

        // Staking Rewards: 5,000,000 TETH (50%)
        assertEq(tetra.balanceOf(stakingRewards), 5_000_000 * 10 ** 18);

        // Team: 2,000,000 TETH (20%)
        assertEq(tetra.balanceOf(team), 2_000_000 * 10 ** 18);

        // Treasury: 1,000,000 TETH (10%)
        assertEq(tetra.balanceOf(treasury), 1_000_000 * 10 ** 18);
    }

    function testNoSupplyIncrease() public {
        // Initial supply
        uint256 initialSupply = tetra.totalSupply();

        // Do some transfers
        vm.prank(liquidityMining);
        tetra.transfer(user, 1000 * 10 ** 18);

        vm.prank(stakingRewards);
        tetra.transfer(user, 500 * 10 ** 18);

        // Supply should remain the same
        assertEq(tetra.totalSupply(), initialSupply);
    }

    // ====================
    // EDGE CASES
    // ====================

    function testTransferAllTokens() public {
        uint256 balance = tetra.balanceOf(liquidityMining);

        vm.prank(liquidityMining);
        tetra.transfer(user, balance);

        assertEq(tetra.balanceOf(liquidityMining), 0);
        assertEq(tetra.balanceOf(user), balance);
    }

    function testMultipleTransfersFromSameSource() public {
        vm.startPrank(team);

        tetra.transfer(user, 100 * 10 ** 18);
        tetra.transfer(user, 200 * 10 ** 18);
        tetra.transfer(user, 300 * 10 ** 18);

        vm.stopPrank();

        assertEq(tetra.balanceOf(user), 600 * 10 ** 18);
    }

    function testComplexTransferChain() public {
        address user2 = address(0x6);
        address user3 = address(0x7);

        // Chain of transfers
        vm.prank(liquidityMining);
        tetra.transfer(user, 1000 * 10 ** 18);

        vm.prank(user);
        tetra.transfer(user2, 400 * 10 ** 18);

        vm.prank(user2);
        tetra.transfer(user3, 200 * 10 ** 18);

        assertEq(tetra.balanceOf(user), 600 * 10 ** 18);
        assertEq(tetra.balanceOf(user2), 200 * 10 ** 18);
        assertEq(tetra.balanceOf(user3), 200 * 10 ** 18);
    }

    // ====================
    // FUZZ TESTS
    // ====================

    function testFuzz_Transfer(uint256 amount) public {
        uint256 liquidityBalance = tetra.balanceOf(liquidityMining);
        amount = bound(amount, 1, liquidityBalance);

        vm.prank(liquidityMining);
        tetra.transfer(user, amount);

        assertEq(tetra.balanceOf(user), amount);
        assertEq(tetra.balanceOf(liquidityMining), liquidityBalance - amount);
    }

    function testFuzz_ApproveAndTransferFrom(uint256 amount) public {
        uint256 liquidityBalance = tetra.balanceOf(liquidityMining);
        amount = bound(amount, 1, liquidityBalance);

        vm.prank(liquidityMining);
        tetra.approve(user, amount);

        vm.prank(user);
        tetra.transferFrom(liquidityMining, user, amount);

        assertEq(tetra.balanceOf(user), amount);
    }

    function testFuzz_MultipleTransfers(uint8 numTransfers) public {
        numTransfers = uint8(bound(numTransfers, 1, 10));

        uint256 amountPerTransfer = 100 * 10 ** 18;
        uint256 totalAmount = uint256(numTransfers) * amountPerTransfer;

        vm.assume(totalAmount <= tetra.balanceOf(liquidityMining));

        vm.startPrank(liquidityMining);
        for (uint8 i = 0; i < numTransfers; i++) {
            tetra.transfer(user, amountPerTransfer);
        }
        vm.stopPrank();

        assertEq(tetra.balanceOf(user), totalAmount);
    }
}

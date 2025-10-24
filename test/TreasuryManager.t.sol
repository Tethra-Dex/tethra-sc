// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/treasury/TreasuryManager.sol";
import "../src/token/MockUSDC.sol";

contract TreasuryManagerTest is Test {
    TreasuryManager public treasury;
    MockUSDC public usdc;

    address public owner;
    address public executor;
    address public keeper;
    address public trader1;
    address public trader2;
    address public stakingRewards;
    address public protocolTreasury;
    address public liquidityProvider;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 constant INITIAL_MINT = 1000000e6; // 1M USDC

    event FeeCollected(address indexed from, uint256 amount, uint256 timestamp);
    event ExecutionFeeCollected(address indexed from, uint256 amount, uint256 timestamp);
    event CollateralRefunded(address indexed to, uint256 amount, uint256 timestamp);
    event ProfitDistributed(address indexed to, uint256 amount, uint256 timestamp);
    event KeeperFeePaid(address indexed keeper, uint256 amount, uint256 timestamp);
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 timestamp);
    event LiquidityRemoved(address indexed provider, uint256 amount, uint256 timestamp);
    event FeesDistributed(uint256 toLiquidity, uint256 toStaking, uint256 toTreasury, uint256 timestamp);
    event FeeDistributionUpdated(uint256 feeToLiquidity, uint256 feeToStaking, uint256 feeToTreasury);
    event AddressesUpdated(address stakingRewards, address protocolTreasury);

    function setUp() public {
        owner = address(this);
        executor = makeAddr("executor");
        keeper = makeAddr("keeper");
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        stakingRewards = makeAddr("stakingRewards");
        protocolTreasury = makeAddr("protocolTreasury");
        liquidityProvider = makeAddr("liquidityProvider");

        // Deploy MockUSDC
        usdc = new MockUSDC(10000000e6); // 10M supply

        // Deploy TreasuryManager
        treasury = new TreasuryManager(address(usdc), stakingRewards, protocolTreasury);

        // Grant roles
        treasury.grantRole(EXECUTOR_ROLE, executor);
        treasury.grantRole(KEEPER_ROLE, keeper);

        // Mint USDC to various addresses
        usdc.mint(address(treasury), INITIAL_MINT);
        usdc.mint(liquidityProvider, 100000e6);
        usdc.mint(trader1, 10000e6);
        usdc.mint(trader2, 10000e6);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeployment() public view {
        assertEq(address(treasury.usdc()), address(usdc));
        assertEq(treasury.stakingRewards(), stakingRewards);
        assertEq(treasury.protocolTreasury(), protocolTreasury);

        // Check default admin role
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), owner));

        // Check fee distribution defaults
        assertEq(treasury.feeToLiquidity(), 5000); // 50%
        assertEq(treasury.feeToStaking(), 3000); // 30%
        assertEq(treasury.feeToTreasury(), 2000); // 20%
    }

    function testDeployment_InvalidUSDC() public {
        vm.expectRevert("TreasuryManager: Invalid USDC");
        new TreasuryManager(address(0), stakingRewards, protocolTreasury);
    }

    function testDeployment_InvalidStaking() public {
        vm.expectRevert("TreasuryManager: Invalid staking");
        new TreasuryManager(address(usdc), address(0), protocolTreasury);
    }

    function testDeployment_InvalidTreasury() public {
        vm.expectRevert("TreasuryManager: Invalid treasury");
        new TreasuryManager(address(usdc), stakingRewards, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        FEE COLLECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCollectFee() public {
        uint256 feeAmount = 100e6;

        vm.prank(executor);
        vm.expectEmit(true, false, false, true);
        emit FeeCollected(trader1, feeAmount, block.timestamp);

        treasury.collectFee(trader1, feeAmount);

        assertEq(treasury.totalFees(), feeAmount);
        assertEq(treasury.totalFeesCollected(), feeAmount);
    }

    function testCollectFee_Multiple() public {
        vm.startPrank(executor);

        treasury.collectFee(trader1, 100e6);
        treasury.collectFee(trader2, 200e6);
        treasury.collectFee(trader1, 50e6);

        vm.stopPrank();

        assertEq(treasury.totalFees(), 350e6);
        assertEq(treasury.totalFeesCollected(), 350e6);
    }

    function testCollectFee_InvalidAmount() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid amount");
        treasury.collectFee(trader1, 0);
    }

    function testCollectFee_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        treasury.collectFee(trader1, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTION FEE COLLECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCollectExecutionFee() public {
        uint256 execFee = 10e6;

        vm.prank(executor);
        vm.expectEmit(true, false, false, true);
        emit ExecutionFeeCollected(trader1, execFee, block.timestamp);

        treasury.collectExecutionFee(trader1, execFee);

        assertEq(treasury.totalExecutionFees(), execFee);
    }

    function testCollectExecutionFee_Multiple() public {
        vm.startPrank(executor);

        treasury.collectExecutionFee(trader1, 10e6);
        treasury.collectExecutionFee(trader2, 20e6);

        vm.stopPrank();

        assertEq(treasury.totalExecutionFees(), 30e6);
    }

    function testCollectExecutionFee_InvalidAmount() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid amount");
        treasury.collectExecutionFee(trader1, 0);
    }

    function testCollectExecutionFee_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        treasury.collectExecutionFee(trader1, 10e6);
    }

    /*//////////////////////////////////////////////////////////////
                    COLLATERAL REFUND TESTS
    //////////////////////////////////////////////////////////////*/

    function testRefundCollateral() public {
        uint256 refundAmount = 1000e6;
        uint256 initialBalance = usdc.balanceOf(trader1);

        vm.prank(executor);
        vm.expectEmit(true, false, false, true);
        emit CollateralRefunded(trader1, refundAmount, block.timestamp);

        treasury.refundCollateral(trader1, refundAmount);

        assertEq(usdc.balanceOf(trader1), initialBalance + refundAmount);
        assertEq(treasury.totalCollateralRefunded(), refundAmount);
    }

    function testRefundCollateral_Multiple() public {
        vm.startPrank(executor);

        treasury.refundCollateral(trader1, 500e6);
        treasury.refundCollateral(trader2, 300e6);

        vm.stopPrank();

        assertEq(treasury.totalCollateralRefunded(), 800e6);
    }

    function testRefundCollateral_InvalidAddress() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid address");
        treasury.refundCollateral(address(0), 100e6);
    }

    function testRefundCollateral_InvalidAmount() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid amount");
        treasury.refundCollateral(trader1, 0);
    }

    function testRefundCollateral_InsufficientBalance() public {
        uint256 tooMuch = INITIAL_MINT + 1;

        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Insufficient balance");
        treasury.refundCollateral(trader1, tooMuch);
    }

    function testRefundCollateral_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        treasury.refundCollateral(trader1, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                    PROFIT DISTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testDistributeProfit() public {
        // First add liquidity
        vm.startPrank(executor);
        treasury.collectFee(trader1, 1000e6);
        vm.stopPrank();

        vm.prank(owner);
        treasury.distributeFees();

        uint256 liquidityBefore = treasury.liquidityPool();
        uint256 profitAmount = 100e6;
        uint256 initialBalance = usdc.balanceOf(trader1);

        vm.prank(executor);
        vm.expectEmit(true, false, false, true);
        emit ProfitDistributed(trader1, profitAmount, block.timestamp);

        treasury.distributeProfit(trader1, profitAmount);

        assertEq(usdc.balanceOf(trader1), initialBalance + profitAmount);
        assertEq(treasury.liquidityPool(), liquidityBefore - profitAmount);
        assertEq(treasury.totalProfitsDistributed(), profitAmount);
    }

    function testDistributeProfit_InsufficientLiquidity() public {
        uint256 profitAmount = 100e6;

        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Insufficient liquidity");
        treasury.distributeProfit(trader1, profitAmount);
    }

    function testDistributeProfit_InvalidAddress() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid address");
        treasury.distributeProfit(address(0), 100e6);
    }

    function testDistributeProfit_InvalidAmount() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid amount");
        treasury.distributeProfit(trader1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    KEEPER FEE PAYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testPayKeeperFee() public {
        // First collect execution fee
        uint256 execFee = 50e6;
        vm.prank(executor);
        treasury.collectExecutionFee(trader1, execFee);

        uint256 paymentAmount = 30e6;
        uint256 initialBalance = usdc.balanceOf(keeper);

        vm.prank(executor);
        vm.expectEmit(true, false, false, true);
        emit KeeperFeePaid(keeper, paymentAmount, block.timestamp);

        treasury.payKeeperFee(keeper, paymentAmount);

        assertEq(usdc.balanceOf(keeper), initialBalance + paymentAmount);
        assertEq(treasury.totalExecutionFees(), execFee - paymentAmount);
        assertEq(treasury.totalKeeperFeesPaid(), paymentAmount);
    }

    function testPayKeeperFee_InsufficientFees() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Insufficient execution fees");
        treasury.payKeeperFee(keeper, 10e6);
    }

    function testPayKeeperFee_InvalidKeeper() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid keeper");
        treasury.payKeeperFee(address(0), 10e6);
    }

    function testPayKeeperFee_InvalidAmount() public {
        vm.prank(executor);
        vm.expectRevert("TreasuryManager: Invalid amount");
        treasury.payKeeperFee(keeper, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY POOL TESTS
    //////////////////////////////////////////////////////////////*/

    function testAddLiquidity() public {
        uint256 amount = 10000e6;

        vm.startPrank(liquidityProvider);
        usdc.approve(address(treasury), amount);

        vm.expectEmit(true, false, false, true);
        emit LiquidityAdded(liquidityProvider, amount, block.timestamp);

        treasury.addLiquidity(amount);
        vm.stopPrank();

        assertEq(treasury.liquidityPool(), amount);
    }

    function testAddLiquidity_Multiple() public {
        vm.startPrank(liquidityProvider);
        usdc.approve(address(treasury), 30000e6);

        treasury.addLiquidity(10000e6);
        treasury.addLiquidity(5000e6);
        treasury.addLiquidity(15000e6);

        vm.stopPrank();

        assertEq(treasury.liquidityPool(), 30000e6);
    }

    function testAddLiquidity_InvalidAmount() public {
        vm.prank(liquidityProvider);
        vm.expectRevert("TreasuryManager: Invalid amount");
        treasury.addLiquidity(0);
    }

    function testRemoveLiquidity() public {
        // First add liquidity
        uint256 amount = 10000e6;
        vm.startPrank(liquidityProvider);
        usdc.approve(address(treasury), amount);
        treasury.addLiquidity(amount);
        vm.stopPrank();

        // Remove liquidity as admin
        uint256 removeAmount = 5000e6;
        uint256 initialBalance = usdc.balanceOf(liquidityProvider);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LiquidityRemoved(liquidityProvider, removeAmount, block.timestamp);

        treasury.removeLiquidity(liquidityProvider, removeAmount);

        assertEq(treasury.liquidityPool(), amount - removeAmount);
        assertEq(usdc.balanceOf(liquidityProvider), initialBalance + removeAmount);
    }

    function testRemoveLiquidity_InsufficientLiquidity() public {
        vm.prank(owner);
        vm.expectRevert("TreasuryManager: Insufficient liquidity");
        treasury.removeLiquidity(liquidityProvider, 1000e6);
    }

    function testRemoveLiquidity_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        treasury.removeLiquidity(trader1, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                    FEE DISTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testDistributeFees() public {
        // Collect fees
        uint256 totalFeeAmount = 10000e6;
        vm.prank(executor);
        treasury.collectFee(trader1, totalFeeAmount);

        // Calculate expected distribution
        uint256 expectedToLiquidity = (totalFeeAmount * 5000) / 10000; // 50%
        uint256 expectedToStaking = (totalFeeAmount * 3000) / 10000; // 30%
        uint256 expectedToTreasury = totalFeeAmount - expectedToLiquidity - expectedToStaking; // 20%

        uint256 stakingBalanceBefore = usdc.balanceOf(stakingRewards);
        uint256 treasuryBalanceBefore = usdc.balanceOf(protocolTreasury);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit FeesDistributed(expectedToLiquidity, expectedToStaking, expectedToTreasury, block.timestamp);

        treasury.distributeFees();

        assertEq(treasury.liquidityPool(), expectedToLiquidity);
        assertEq(usdc.balanceOf(stakingRewards), stakingBalanceBefore + expectedToStaking);
        assertEq(usdc.balanceOf(protocolTreasury), treasuryBalanceBefore + expectedToTreasury);
        assertEq(treasury.totalFees(), 0);
    }

    function testDistributeFees_NoFeesToDistribute() public {
        vm.prank(owner);
        vm.expectRevert("TreasuryManager: No fees to distribute");
        treasury.distributeFees();
    }

    function testDistributeFees_Unauthorized() public {
        vm.prank(executor);
        treasury.collectFee(trader1, 1000e6);

        vm.prank(trader1);
        vm.expectRevert();
        treasury.distributeFees();
    }

    function testUpdateFeeDistribution() public {
        uint256 newLiquidity = 6000;
        uint256 newStaking = 2500;
        uint256 newTreasury = 1500;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit FeeDistributionUpdated(newLiquidity, newStaking, newTreasury);

        treasury.updateFeeDistribution(newLiquidity, newStaking, newTreasury);

        assertEq(treasury.feeToLiquidity(), newLiquidity);
        assertEq(treasury.feeToStaking(), newStaking);
        assertEq(treasury.feeToTreasury(), newTreasury);
    }

    function testUpdateFeeDistribution_InvalidSum() public {
        vm.prank(owner);
        vm.expectRevert("TreasuryManager: Must sum to 10000 bps");
        treasury.updateFeeDistribution(5000, 3000, 3000); // Sum = 11000
    }

    function testUpdateFeeDistribution_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        treasury.updateFeeDistribution(6000, 2500, 1500);
    }

    /*//////////////////////////////////////////////////////////////
                    ADDRESS UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function testUpdateAddresses() public {
        address newStaking = makeAddr("newStaking");
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AddressesUpdated(newStaking, newTreasury);

        treasury.updateAddresses(newStaking, newTreasury);

        assertEq(treasury.stakingRewards(), newStaking);
        assertEq(treasury.protocolTreasury(), newTreasury);
    }

    function testUpdateAddresses_OnlyStaking() public {
        address newStaking = makeAddr("newStaking");

        vm.prank(owner);
        treasury.updateAddresses(newStaking, address(0));

        assertEq(treasury.stakingRewards(), newStaking);
        assertEq(treasury.protocolTreasury(), protocolTreasury); // Unchanged
    }

    function testUpdateAddresses_OnlyTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        treasury.updateAddresses(address(0), newTreasury);

        assertEq(treasury.stakingRewards(), stakingRewards); // Unchanged
        assertEq(treasury.protocolTreasury(), newTreasury);
    }

    function testUpdateAddresses_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        treasury.updateAddresses(makeAddr("newStaking"), makeAddr("newTreasury"));
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetTotalBalance() public view {
        assertEq(treasury.getTotalBalance(), INITIAL_MINT);
    }

    function testGetAvailableLiquidity() public {
        vm.startPrank(liquidityProvider);
        usdc.approve(address(treasury), 10000e6);
        treasury.addLiquidity(10000e6);
        vm.stopPrank();

        assertEq(treasury.getAvailableLiquidity(), 10000e6);
    }

    function testGetPendingFees() public {
        vm.prank(executor);
        treasury.collectFee(trader1, 500e6);

        assertEq(treasury.getPendingFees(), 500e6);
    }

    function testGetPendingExecutionFees() public {
        vm.prank(executor);
        treasury.collectExecutionFee(trader1, 50e6);

        assertEq(treasury.getPendingExecutionFees(), 50e6);
    }

    function testGetStatistics() public {
        vm.startPrank(executor);
        treasury.collectFee(trader1, 1000e6);
        treasury.refundCollateral(trader1, 500e6);
        treasury.collectExecutionFee(trader1, 50e6);
        treasury.payKeeperFee(keeper, 30e6);
        vm.stopPrank();

        vm.prank(owner);
        treasury.distributeFees();

        vm.prank(executor);
        treasury.distributeProfit(trader2, 100e6);

        (
            uint256 feesCollected,
            uint256 profitsDistributed,
            uint256 collateralRefunded,
            uint256 keeperFeesPaid,
            uint256 relayerFeesPaid
        ) = treasury.getStatistics();

        assertEq(feesCollected, 1000e6);
        assertEq(profitsDistributed, 100e6);
        assertEq(collateralRefunded, 500e6);
        assertEq(keeperFeesPaid, 30e6);
    }

    function testGetFeeDistribution() public view {
        (uint256 toLiquidity, uint256 toStaking, uint256 toTreasury) = treasury.getFeeDistribution();

        assertEq(toLiquidity, 5000);
        assertEq(toStaking, 3000);
        assertEq(toTreasury, 2000);
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function testEmergencyWithdraw_ERC20() public {
        uint256 withdrawAmount = 10000e6;
        uint256 initialBalance = usdc.balanceOf(owner);

        vm.prank(owner);
        treasury.emergencyWithdraw(address(usdc), owner, withdrawAmount);

        assertEq(usdc.balanceOf(owner), initialBalance + withdrawAmount);
    }

    function testEmergencyWithdraw_InvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert("TreasuryManager: Invalid address");
        treasury.emergencyWithdraw(address(usdc), address(0), 100e6);
    }

    function testEmergencyWithdraw_InvalidAmount() public {
        vm.prank(owner);
        vm.expectRevert("TreasuryManager: Invalid amount");
        treasury.emergencyWithdraw(address(usdc), owner, 0);
    }

    function testEmergencyWithdraw_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        treasury.emergencyWithdraw(address(usdc), trader1, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                            INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testIntegration_CompleteFlow() public {
        // 1. Add liquidity
        vm.startPrank(liquidityProvider);
        usdc.approve(address(treasury), 50000e6);
        treasury.addLiquidity(50000e6);
        vm.stopPrank();

        // 2. Collect fees and execution fees
        vm.startPrank(executor);
        treasury.collectFee(trader1, 1000e6);
        treasury.collectFee(trader2, 2000e6);
        treasury.collectExecutionFee(trader1, 50e6);
        treasury.collectExecutionFee(trader2, 100e6);
        vm.stopPrank();

        assertEq(treasury.totalFees(), 3000e6);
        assertEq(treasury.totalExecutionFees(), 150e6);

        // 3. Distribute fees
        vm.prank(owner);
        treasury.distributeFees();

        uint256 expectedLiquidity = 50000e6 + (3000e6 * 5000 / 10000);
        assertEq(treasury.liquidityPool(), expectedLiquidity);

        // 4. Distribute profit to trader
        vm.prank(executor);
        treasury.distributeProfit(trader1, 1000e6);

        assertEq(treasury.totalProfitsDistributed(), 1000e6);

        // 5. Pay keeper fees
        vm.prank(executor);
        treasury.payKeeperFee(keeper, 100e6);

        assertEq(treasury.totalKeeperFeesPaid(), 100e6);
        assertEq(treasury.totalExecutionFees(), 50e6);

        // 6. Refund collateral
        vm.prank(executor);
        treasury.refundCollateral(trader2, 500e6);

        assertEq(treasury.totalCollateralRefunded(), 500e6);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CollectFee(uint256 amount) public {
        amount = bound(amount, 1, 1000000e6);

        vm.prank(executor);
        treasury.collectFee(trader1, amount);

        assertEq(treasury.totalFees(), amount);
        assertEq(treasury.totalFeesCollected(), amount);
    }

    function testFuzz_FeeDistribution(uint256 toLiquidity, uint256 toStaking) public {
        toLiquidity = bound(toLiquidity, 0, 10000);
        toStaking = bound(toStaking, 0, 10000 - toLiquidity);
        uint256 toTreasury = 10000 - toLiquidity - toStaking;

        vm.prank(owner);
        treasury.updateFeeDistribution(toLiquidity, toStaking, toTreasury);

        (uint256 liq, uint256 stak, uint256 treas) = treasury.getFeeDistribution();
        assertEq(liq + stak + treas, 10000);
    }
}

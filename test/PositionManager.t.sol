// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/trading/PositionManager.sol";

contract PositionManagerTest is Test {
    PositionManager public positionManager;

    address public owner;
    address public executor;
    address public trader1;
    address public trader2;
    address public liquidator;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // Test position parameters
    string constant SYMBOL_BTC = "BTC";
    uint256 constant COLLATERAL = 1000e6; // 1000 USDC
    uint256 constant LEVERAGE = 10;
    uint256 constant ENTRY_PRICE = 50000e8; // $50,000
    uint256 constant EXIT_PRICE = 55000e8; // $55,000

    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        string symbol,
        bool isLong,
        uint256 collateral,
        uint256 size,
        uint256 leverage,
        uint256 entryPrice
    );

    event PositionClosed(uint256 indexed positionId, uint256 exitPrice, int256 pnl);

    event PositionLiquidated(uint256 indexed positionId, uint256 liquidationPrice, address liquidator);

    function setUp() public {
        owner = address(this);
        executor = makeAddr("executor");
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        liquidator = makeAddr("liquidator");

        positionManager = new PositionManager();

        // Grant EXECUTOR_ROLE to executor
        positionManager.grantRole(EXECUTOR_ROLE, executor);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeployment() public view {
        // Check that owner has DEFAULT_ADMIN_ROLE
        assertTrue(positionManager.hasRole(positionManager.DEFAULT_ADMIN_ROLE(), owner));

        // Check that owner has EXECUTOR_ROLE
        assertTrue(positionManager.hasRole(EXECUTOR_ROLE, owner));

        // Check initial position ID
        assertEq(positionManager.nextPositionId(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        CREATE POSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreatePosition_Long() public {
        vm.startPrank(executor);

        vm.expectEmit(true, true, false, true);
        emit PositionOpened(1, trader1, SYMBOL_BTC, true, COLLATERAL, COLLATERAL * LEVERAGE, LEVERAGE, ENTRY_PRICE);

        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        assertEq(positionId, 1);
        assertEq(positionManager.nextPositionId(), 2);

        PositionManager.Position memory position = positionManager.getPosition(1);
        assertEq(position.id, 1);
        assertEq(position.trader, trader1);
        assertEq(position.symbol, SYMBOL_BTC);
        assertTrue(position.isLong);
        assertEq(position.collateral, COLLATERAL);
        assertEq(position.size, COLLATERAL * LEVERAGE);
        assertEq(position.leverage, LEVERAGE);
        assertEq(position.entryPrice, ENTRY_PRICE);
        assertEq(uint256(position.status), uint256(PositionManager.PositionStatus.OPEN));

        vm.stopPrank();
    }

    function testCreatePosition_Short() public {
        vm.prank(executor);
        uint256 positionId = positionManager.createPosition(
            trader1,
            SYMBOL_BTC,
            false, // short
            COLLATERAL,
            LEVERAGE,
            ENTRY_PRICE
        );

        PositionManager.Position memory position = positionManager.getPosition(positionId);
        assertFalse(position.isLong);
    }

    function testCreatePosition_MultiplePositions() public {
        vm.startPrank(executor);

        // Create first position
        uint256 positionId1 =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        // Create second position
        uint256 positionId2 = positionManager.createPosition(trader1, "ETH", false, 2000e6, 5, 3000e8);

        assertEq(positionId1, 1);
        assertEq(positionId2, 2);
        assertEq(positionManager.nextPositionId(), 3);

        // Check user positions
        uint256[] memory userPositions = positionManager.getUserPositions(trader1);
        assertEq(userPositions.length, 2);
        assertEq(userPositions[0], 1);
        assertEq(userPositions[1], 2);

        vm.stopPrank();
    }

    function testCreatePosition_InvalidTrader() public {
        vm.prank(executor);
        vm.expectRevert("PositionManager: Invalid trader");
        positionManager.createPosition(address(0), SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);
    }

    function testCreatePosition_InvalidCollateral() public {
        vm.prank(executor);
        vm.expectRevert("PositionManager: Invalid collateral");
        positionManager.createPosition(trader1, SYMBOL_BTC, true, 0, LEVERAGE, ENTRY_PRICE);
    }

    function testCreatePosition_InvalidLeverage() public {
        vm.prank(executor);
        vm.expectRevert("PositionManager: Invalid leverage");
        positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, 0, ENTRY_PRICE);
    }

    function testCreatePosition_InvalidPrice() public {
        vm.prank(executor);
        vm.expectRevert("PositionManager: Invalid price");
        positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, 0);
    }

    function testCreatePosition_Unauthorized() public {
        vm.prank(trader1);
        vm.expectRevert();
        positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE POSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function testClosePosition_Long_Profit() public {
        vm.startPrank(executor);

        // Create position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        // Close position at higher price (profit)
        vm.expectEmit(true, false, false, true);
        emit PositionClosed(positionId, EXIT_PRICE, 1000e6);

        int256 pnl = positionManager.closePosition(positionId, EXIT_PRICE);

        // PnL = (55000 - 50000) / 50000 * 10000e6 = 1000e6
        assertEq(pnl, 1000e6);

        PositionManager.Position memory position = positionManager.getPosition(positionId);
        assertEq(uint256(position.status), uint256(PositionManager.PositionStatus.CLOSED));

        vm.stopPrank();
    }

    function testClosePosition_Long_Loss() public {
        vm.startPrank(executor);

        // Create position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        // Close position at lower price (loss)
        uint256 lowerExitPrice = 45000e8;
        int256 pnl = positionManager.closePosition(positionId, lowerExitPrice);

        // PnL = (45000 - 50000) / 50000 * 10000e6 = -1000e6
        assertEq(pnl, -1000e6);

        vm.stopPrank();
    }

    function testClosePosition_Short_Profit() public {
        vm.startPrank(executor);

        // Create short position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, false, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        // Close position at lower price (profit for short)
        uint256 lowerExitPrice = 45000e8;
        int256 pnl = positionManager.closePosition(positionId, lowerExitPrice);

        // PnL = (50000 - 45000) / 50000 * 10000e6 = 1000e6
        assertEq(pnl, 1000e6);

        vm.stopPrank();
    }

    function testClosePosition_Short_Loss() public {
        vm.startPrank(executor);

        // Create short position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, false, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        // Close position at higher price (loss for short)
        int256 pnl = positionManager.closePosition(positionId, EXIT_PRICE);

        // PnL = (50000 - 55000) / 50000 * 10000e6 = -1000e6
        assertEq(pnl, -1000e6);

        vm.stopPrank();
    }

    function testClosePosition_NotFound() public {
        vm.prank(executor);
        vm.expectRevert("PositionManager: Position not found");
        positionManager.closePosition(999, EXIT_PRICE);
    }

    function testClosePosition_AlreadyClosed() public {
        vm.startPrank(executor);

        // Create and close position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);
        positionManager.closePosition(positionId, EXIT_PRICE);

        // Try to close again
        vm.expectRevert("PositionManager: Position not open");
        positionManager.closePosition(positionId, EXIT_PRICE);

        vm.stopPrank();
    }

    function testClosePosition_InvalidExitPrice() public {
        vm.startPrank(executor);

        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        vm.expectRevert("PositionManager: Invalid exit price");
        positionManager.closePosition(positionId, 0);

        vm.stopPrank();
    }

    function testClosePosition_Unauthorized() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        vm.prank(trader1);
        vm.expectRevert();
        positionManager.closePosition(positionId, EXIT_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATE POSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function testLiquidatePosition() public {
        vm.startPrank(executor);

        // Create position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        uint256 liquidationPrice = 45000e8;

        vm.expectEmit(true, false, false, true);
        emit PositionLiquidated(positionId, liquidationPrice, executor);

        positionManager.liquidatePosition(positionId, liquidationPrice);

        PositionManager.Position memory position = positionManager.getPosition(positionId);
        assertEq(uint256(position.status), uint256(PositionManager.PositionStatus.LIQUIDATED));

        vm.stopPrank();
    }

    function testLiquidatePosition_NotFound() public {
        vm.prank(executor);
        vm.expectRevert("PositionManager: Position not found");
        positionManager.liquidatePosition(999, 45000e8);
    }

    function testLiquidatePosition_AlreadyClosed() public {
        vm.startPrank(executor);

        // Create and close position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);
        positionManager.closePosition(positionId, EXIT_PRICE);

        // Try to liquidate
        vm.expectRevert("PositionManager: Position not open");
        positionManager.liquidatePosition(positionId, 45000e8);

        vm.stopPrank();
    }

    function testLiquidatePosition_Unauthorized() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        vm.prank(trader1);
        vm.expectRevert();
        positionManager.liquidatePosition(positionId, 45000e8);
    }

    /*//////////////////////////////////////////////////////////////
                        CALCULATE PNL TESTS
    //////////////////////////////////////////////////////////////*/

    function testCalculatePnL_Long_Profit() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        int256 pnl = positionManager.calculatePnL(positionId, EXIT_PRICE);
        assertEq(pnl, 1000e6);
    }

    function testCalculatePnL_Long_Loss() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        int256 pnl = positionManager.calculatePnL(positionId, 45000e8);
        assertEq(pnl, -1000e6);
    }

    function testCalculatePnL_Short_Profit() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, false, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        int256 pnl = positionManager.calculatePnL(positionId, 45000e8);
        assertEq(pnl, 1000e6);
    }

    function testCalculatePnL_Short_Loss() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, false, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        int256 pnl = positionManager.calculatePnL(positionId, EXIT_PRICE);
        assertEq(pnl, -1000e6);
    }

    function testCalculatePnL_NoChange() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        int256 pnl = positionManager.calculatePnL(positionId, ENTRY_PRICE);
        assertEq(pnl, 0);
    }

    function testCalculatePnL_PositionNotFound() public {
        vm.expectRevert("PositionManager: Position not found");
        positionManager.calculatePnL(999, EXIT_PRICE);
    }

    function testCalculatePnL_InvalidPrice() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        vm.expectRevert("PositionManager: Invalid price");
        positionManager.calculatePnL(positionId, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        USER POSITION QUERIES
    //////////////////////////////////////////////////////////////*/

    function testGetUserPositions() public {
        vm.startPrank(executor);

        // Create positions for trader1
        positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);
        positionManager.createPosition(trader1, "ETH", false, 2000e6, 5, 3000e8);

        // Create position for trader2
        positionManager.createPosition(trader2, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        vm.stopPrank();

        uint256[] memory trader1Positions = positionManager.getUserPositions(trader1);
        assertEq(trader1Positions.length, 2);
        assertEq(trader1Positions[0], 1);
        assertEq(trader1Positions[1], 2);

        uint256[] memory trader2Positions = positionManager.getUserPositions(trader2);
        assertEq(trader2Positions.length, 1);
        assertEq(trader2Positions[0], 3);
    }

    function testGetUserOpenPositions() public {
        vm.startPrank(executor);

        // Create 3 positions
        uint256 pos1 = positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);
        uint256 pos2 = positionManager.createPosition(trader1, "ETH", false, 2000e6, 5, 3000e8);
        positionManager.createPosition(trader1, "SOL", true, 500e6, 3, 100e8);

        // Close first position
        positionManager.closePosition(pos1, EXIT_PRICE);

        // Liquidate second position
        positionManager.liquidatePosition(pos2, 2500e8);

        vm.stopPrank();

        // Only third position should be open
        PositionManager.Position[] memory openPositions = positionManager.getUserOpenPositions(trader1);
        assertEq(openPositions.length, 1);
        assertEq(openPositions[0].id, 3);
        assertEq(openPositions[0].symbol, "SOL");
    }

    function testGetUserOpenPositions_NoPositions() public view {
        PositionManager.Position[] memory openPositions = positionManager.getUserOpenPositions(trader1);
        assertEq(openPositions.length, 0);
    }

    function testGetUserOpenPositions_AllClosed() public {
        vm.startPrank(executor);

        uint256 pos1 = positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);
        uint256 pos2 = positionManager.createPosition(trader1, "ETH", false, 2000e6, 5, 3000e8);

        positionManager.closePosition(pos1, EXIT_PRICE);
        positionManager.closePosition(pos2, 3500e8);

        vm.stopPrank();

        PositionManager.Position[] memory openPositions = positionManager.getUserOpenPositions(trader1);
        assertEq(openPositions.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION STATUS QUERIES
    //////////////////////////////////////////////////////////////*/

    function testPositionExists() public {
        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        assertTrue(positionManager.positionExists(positionId));
        assertFalse(positionManager.positionExists(999));
    }

    function testGetPositionStatus() public {
        vm.startPrank(executor);

        // Create position
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, true, COLLATERAL, LEVERAGE, ENTRY_PRICE);

        assertEq(uint256(positionManager.getPositionStatus(positionId)), uint256(PositionManager.PositionStatus.OPEN));

        // Close position
        positionManager.closePosition(positionId, EXIT_PRICE);

        assertEq(uint256(positionManager.getPositionStatus(positionId)), uint256(PositionManager.PositionStatus.CLOSED));

        vm.stopPrank();
    }

    function testGetPositionStatus_NotFound() public {
        vm.expectRevert("PositionManager: Position not found");
        positionManager.getPositionStatus(999);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CreatePosition(uint256 collateral, uint256 leverage, uint256 entryPrice) public {
        // Bound inputs to reasonable ranges
        collateral = bound(collateral, 1e6, 100000e6); // 1 to 100,000 USDC
        leverage = bound(leverage, 1, 100); // 1x to 100x
        entryPrice = bound(entryPrice, 1e8, 1000000e8); // $1 to $1,000,000

        vm.prank(executor);
        uint256 positionId = positionManager.createPosition(trader1, SYMBOL_BTC, true, collateral, leverage, entryPrice);

        PositionManager.Position memory position = positionManager.getPosition(positionId);
        assertEq(position.collateral, collateral);
        assertEq(position.leverage, leverage);
        assertEq(position.size, collateral * leverage);
        assertEq(position.entryPrice, entryPrice);
    }

    function testFuzz_CalculatePnL(uint256 entryPrice, uint256 exitPrice, bool isLong) public {
        // Bound prices to reasonable ranges
        entryPrice = bound(entryPrice, 1000e8, 100000e8);
        exitPrice = bound(exitPrice, 1000e8, 100000e8);

        vm.prank(executor);
        uint256 positionId =
            positionManager.createPosition(trader1, SYMBOL_BTC, isLong, COLLATERAL, LEVERAGE, entryPrice);

        int256 pnl = positionManager.calculatePnL(positionId, exitPrice);

        // Verify PnL formula
        int256 priceDiff;
        if (isLong) {
            priceDiff = int256(exitPrice) - int256(entryPrice);
        } else {
            priceDiff = int256(entryPrice) - int256(exitPrice);
        }

        int256 expectedPnl = (priceDiff * int256(COLLATERAL * LEVERAGE)) / int256(entryPrice);
        assertEq(pnl, expectedPnl);
    }
}

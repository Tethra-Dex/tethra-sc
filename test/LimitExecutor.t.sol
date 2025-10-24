// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/trading/LimitExecutor.sol";
import "../src/trading/PositionManager.sol";
import "../src/risk/RiskManager.sol";
import "../src/treasury/TreasuryManager.sol";
import "../src/token/MockUSDC.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract LimitExecutorTest is Test {
    using MessageHashUtils for bytes32;

    LimitExecutor public executor;
    PositionManager public positionManager;
    RiskManager public riskManager;
    TreasuryManager public treasury;
    MockUSDC public usdc;

    address public admin;
    address public trader1;
    address public trader2;
    address public keeper;

    uint256 public backendSignerPK = 0xABC123;
    address public backendSigner;

    uint256 constant INITIAL_BALANCE = 100_000e6; // 100K USDC
    uint256 constant COLLATERAL = 1000e6; // 1000 USDC
    uint256 constant LEVERAGE = 10;
    uint256 constant BTC_PRICE = 95000e8; // $95,000
    uint256 constant TRIGGER_PRICE_LONG = 90000e8; // $90,000 (buy when drops)
    uint256 constant TRIGGER_PRICE_SHORT = 100000e8; // $100,000 (sell when rises)

    // Events to test
    event LimitOrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        LimitExecutor.OrderType orderType,
        string symbol,
        uint256 triggerPrice,
        uint256 executionFee
    );

    event LimitOrderExecuted(
        uint256 indexed orderId,
        uint256 indexed positionId,
        address indexed keeper,
        uint256 executionPrice,
        uint256 keeperFee
    );

    event LimitOrderCancelled(uint256 indexed orderId, address indexed trader);

    function setUp() public {
        admin = address(this);
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        keeper = makeAddr("keeper");
        backendSigner = vm.addr(backendSignerPK);

        // Deploy contracts
        usdc = new MockUSDC(10_000_000); // 10M USDC
        riskManager = new RiskManager();
        positionManager = new PositionManager();

        address stakingRewards = makeAddr("stakingRewards");
        address protocolTreasury = makeAddr("protocolTreasury");
        treasury = new TreasuryManager(address(usdc), stakingRewards, protocolTreasury);

        executor = new LimitExecutor(
            address(usdc), address(riskManager), address(positionManager), address(treasury), keeper, backendSigner
        );

        // Grant roles
        positionManager.grantRole(positionManager.EXECUTOR_ROLE(), address(executor));
        treasury.grantRole(treasury.EXECUTOR_ROLE(), address(executor));

        // Add supported asset
        riskManager.setAssetConfig("BTC", true, 20, 100_000e6, 1_000_000e6, 7500);

        // Fund traders
        usdc.transfer(trader1, INITIAL_BALANCE);
        usdc.transfer(trader2, INITIAL_BALANCE);

        // Fund treasury (for payouts and settlements)
        usdc.transfer(address(treasury), 5_000_000e6); // 5M USDC
    }

    // ========================================
    // TEST 1: Create Limit Open Order (Long)
    // ========================================
    function testCreateLimitOpenOrder_Long() public {
        vm.startPrank(trader1);

        // Approve USDC (collateral + execution fee)
        uint256 executionFee = executor.executionFee();
        uint256 totalAmount = COLLATERAL + executionFee;
        usdc.approve(address(executor), totalAmount);

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit LimitOrderCreated(1, trader1, LimitExecutor.OrderType.LIMIT_OPEN, "BTC", TRIGGER_PRICE_LONG, executionFee);

        // Create limit order
        uint256 orderId = executor.createLimitOpenOrder(
            "BTC",
            true, // isLong
            COLLATERAL,
            LEVERAGE,
            TRIGGER_PRICE_LONG
        );

        vm.stopPrank();

        // Verify order created
        assertEq(orderId, 1, "Order ID should be 1");

        // Get order details
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        assertEq(order.trader, trader1, "Trader mismatch");
        assertEq(order.symbol, "BTC", "Symbol mismatch");
        assertEq(order.isLong, true, "isLong should be true");
        assertEq(order.collateral, COLLATERAL, "Collateral mismatch");
        assertEq(order.leverage, LEVERAGE, "Leverage mismatch");
        assertEq(order.triggerPrice, TRIGGER_PRICE_LONG, "Trigger price mismatch");
        assertEq(uint8(order.status), uint8(LimitExecutor.OrderStatus.PENDING), "Status should be PENDING");
        assertEq(uint8(order.orderType), uint8(LimitExecutor.OrderType.LIMIT_OPEN), "OrderType should be LIMIT_OPEN");
    }

    // ========================================
    // TEST 2: Create Limit Open Order (Short)
    // ========================================
    function testCreateLimitOpenOrder_Short() public {
        vm.startPrank(trader1);

        uint256 executionFee = executor.executionFee();
        uint256 totalAmount = COLLATERAL + executionFee;
        usdc.approve(address(executor), totalAmount);

        uint256 orderId = executor.createLimitOpenOrder(
            "BTC",
            false, // isLong = false (Short)
            COLLATERAL,
            LEVERAGE,
            TRIGGER_PRICE_SHORT
        );

        vm.stopPrank();

        LimitExecutor.Order memory order = executor.getOrder(orderId);
        assertEq(order.isLong, false, "isLong should be false for short");
        assertEq(order.triggerPrice, TRIGGER_PRICE_SHORT, "Trigger price mismatch for short");
    }

    // ========================================
    // TEST 3: Cannot Create Order Without Funds
    // ========================================
    function testCannotCreateOrderWithoutFunds() public {
        address poorTrader = makeAddr("poorTrader");

        vm.startPrank(poorTrader);

        vm.expectRevert();
        executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);

        vm.stopPrank();
    }

    // ========================================
    // TEST 4: Cannot Create Order Without Approval
    // ========================================
    function testCannotCreateOrderWithoutApproval() public {
        vm.startPrank(trader1);

        // Don't approve USDC
        vm.expectRevert();
        executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);

        vm.stopPrank();
    }

    // ========================================
    // TEST 5: Execute Limit Open Order (Long)
    // ========================================
    function testExecuteLimitOpenOrder_Long() public {
        // First, trader creates order
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();
        uint256 totalAmount = COLLATERAL + executionFee;
        usdc.approve(address(executor), totalAmount);

        uint256 orderId = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);
        vm.stopPrank();

        // Now keeper executes when price hits trigger
        vm.startPrank(keeper);

        LimitExecutor.SignedPrice memory signedPrice = LimitExecutor.SignedPrice({
            symbol: "BTC",
            price: TRIGGER_PRICE_LONG, // Price hit trigger!
            timestamp: block.timestamp,
            signature: hex"00" // Dummy signature (validation disabled in contract for demo)
        });

        // Expect event - don't check positionId (unknown at this point)
        vm.expectEmit(true, false, true, false);
        emit LimitOrderExecuted(
            orderId,
            0, // positionId will be determined by PositionManager
            keeper,
            TRIGGER_PRICE_LONG,
            executionFee
        );

        executor.executeLimitOpenOrder(orderId, signedPrice);

        vm.stopPrank();

        // Verify order executed
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        assertEq(uint8(order.status), uint8(LimitExecutor.OrderStatus.EXECUTED), "Order should be EXECUTED");
        assertGt(order.positionId, 0, "Position ID should be set");

        // Verify position created - using the struct directly
        PositionManager.Position memory position = positionManager.getPosition(order.positionId);
        assertEq(position.trader, trader1, "Position trader mismatch");
        assertEq(position.symbol, "BTC", "Position symbol mismatch");
        assertEq(position.isLong, true, "Position should be long");
        assertEq(position.collateral, COLLATERAL, "Position collateral mismatch");
        assertEq(position.leverage, LEVERAGE, "Position leverage mismatch");
        assertEq(uint8(position.status), uint8(PositionManager.PositionStatus.OPEN), "Position should be OPEN");
    }

    // ========================================
    // TEST 6: Cannot Execute Before Price Reaches (Long)
    // ========================================
    function testCannotExecuteBeforePriceReaches_Long() public {
        // Create order
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();
        usdc.approve(address(executor), COLLATERAL + executionFee);

        uint256 orderId = executor.createLimitOpenOrder(
            "BTC",
            true, // Long
            COLLATERAL,
            LEVERAGE,
            TRIGGER_PRICE_LONG // Trigger at $90,000
        );
        vm.stopPrank();

        // Try to execute at higher price (not reached yet)
        vm.startPrank(keeper);

        LimitExecutor.SignedPrice memory signedPrice = LimitExecutor.SignedPrice({
            symbol: "BTC",
            price: BTC_PRICE, // $95,000 - still above trigger!
            timestamp: block.timestamp,
            signature: hex"00"
        });

        vm.expectRevert("LimitExecutor: Price not reached (long)");
        executor.executeLimitOpenOrder(orderId, signedPrice);

        vm.stopPrank();
    }

    // ========================================
    // TEST 7: Execute Limit Open Order (Short)
    // ========================================
    function testExecuteLimitOpenOrder_Short() public {
        // Create short order
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();
        usdc.approve(address(executor), COLLATERAL + executionFee);

        uint256 orderId = executor.createLimitOpenOrder(
            "BTC",
            false, // Short
            COLLATERAL,
            LEVERAGE,
            TRIGGER_PRICE_SHORT // $100,000
        );
        vm.stopPrank();

        // Execute when price rises to trigger
        vm.startPrank(keeper);

        LimitExecutor.SignedPrice memory signedPrice = LimitExecutor.SignedPrice({
            symbol: "BTC",
            price: TRIGGER_PRICE_SHORT, // $100,000 - hit trigger!
            timestamp: block.timestamp,
            signature: hex"00"
        });

        executor.executeLimitOpenOrder(orderId, signedPrice);

        vm.stopPrank();

        // Verify position created as short
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        PositionManager.Position memory position = positionManager.getPosition(order.positionId);
        assertEq(position.isLong, false, "Position should be short");
    }

    // ========================================
    // TEST 8: Cancel Limit Order
    // ========================================
    function testCancelLimitOrder() public {
        // Create order
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();
        usdc.approve(address(executor), COLLATERAL + executionFee);

        uint256 orderId = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);

        uint256 balanceBefore = usdc.balanceOf(trader1);

        // Expect event
        vm.expectEmit(true, true, false, false);
        emit LimitOrderCancelled(orderId, trader1);

        // Cancel order
        executor.cancelOrder(orderId);

        vm.stopPrank();

        // Verify order cancelled
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        assertEq(uint8(order.status), uint8(LimitExecutor.OrderStatus.CANCELLED), "Order should be CANCELLED");

        // Verify funds refunded (collateral + execution fee)
        uint256 balanceAfter = usdc.balanceOf(trader1);
        assertEq(balanceAfter - balanceBefore, COLLATERAL + executionFee, "Funds should be refunded");
    }

    // ========================================
    // TEST 9: Cannot Cancel Other's Order
    // ========================================
    function testCannotCancelOthersOrder() public {
        // Trader1 creates order
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();
        usdc.approve(address(executor), COLLATERAL + executionFee);

        uint256 orderId = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);
        vm.stopPrank();

        // Trader2 tries to cancel
        vm.startPrank(trader2);

        vm.expectRevert("LimitExecutor: Not order owner");
        executor.cancelOrder(orderId);

        vm.stopPrank();
    }

    // ========================================
    // TEST 10: Create Take Profit Order
    // ========================================
    function testCreateTakeProfitOrder() public {
        uint256 executionFee = executor.executionFee();

        // Step 1: Create and execute limit open order
        vm.startPrank(trader1);
        // FIXED: Approve untuk limit open order
        usdc.approve(address(executor), COLLATERAL + executionFee);

        uint256 orderId = executor.createLimitOpenOrder(
            "BTC",
            true, // Long
            COLLATERAL,
            LEVERAGE,
            TRIGGER_PRICE_LONG
        );
        vm.stopPrank();

        // Execute order
        vm.startPrank(keeper);
        LimitExecutor.SignedPrice memory signedPrice =
            LimitExecutor.SignedPrice({symbol: "BTC", price: TRIGGER_PRICE_LONG, timestamp: block.timestamp, signature: hex"00"});
        executor.executeLimitOpenOrder(orderId, signedPrice);
        vm.stopPrank();

        // Get position ID
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        uint256 positionId = order.positionId;

        // Step 2: Now create Take Profit order
        vm.startPrank(trader1);
        // FIXED: Approve LAGI untuk TP order execution fee
        usdc.approve(address(executor), executionFee);

        uint256 tpPrice = 100000e8; // Take profit at $100,000
        uint256 tpOrderId = executor.createLimitCloseOrder(positionId, tpPrice);
        vm.stopPrank();

        // Verify TP order created
        LimitExecutor.Order memory tpOrder = executor.getOrder(tpOrderId);
        assertEq(
            uint8(tpOrder.orderType), uint8(LimitExecutor.OrderType.LIMIT_CLOSE), "OrderType should be LIMIT_CLOSE"
        );
        assertEq(tpOrder.positionId, positionId, "Position ID mismatch");
        assertEq(tpOrder.triggerPrice, tpPrice, "TP price mismatch");
    }

    // ========================================
    // TEST 11: Create Stop Loss Order
    // ========================================
    function testCreateStopLossOrder() public {
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();

        // FIXED: Approve untuk limit open order saja dulu
        usdc.approve(address(executor), COLLATERAL + executionFee);

        // First, open a position
        uint256 orderId = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);
        vm.stopPrank();

        // Execute order
        vm.startPrank(keeper);
        LimitExecutor.SignedPrice memory signedPrice =
            LimitExecutor.SignedPrice({symbol: "BTC", price: TRIGGER_PRICE_LONG, timestamp: block.timestamp, signature: hex"00"});
        executor.executeLimitOpenOrder(orderId, signedPrice);
        vm.stopPrank();

        // Get position ID
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        uint256 positionId = order.positionId;

        // Create Stop Loss order
        vm.startPrank(trader1);
        // FIXED: Approve LAGI untuk SL order execution fee
        usdc.approve(address(executor), executionFee);

        uint256 slPrice = 85000e8; // Stop loss at $85,000
        uint256 slOrderId = executor.createStopLossOrder(positionId, slPrice);
        vm.stopPrank();

        // Verify SL order created
        LimitExecutor.Order memory slOrder = executor.getOrder(slOrderId);
        assertEq(uint8(slOrder.orderType), uint8(LimitExecutor.OrderType.STOP_LOSS), "OrderType should be STOP_LOSS");
        assertEq(slOrder.positionId, positionId, "Position ID mismatch");
        assertEq(slOrder.triggerPrice, slPrice, "SL price mismatch");
    }

    // ========================================
    // TEST 12: Execute Take Profit (Long Position)
    // ========================================
    function testExecuteTakeProfit_LongPosition() public {
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();

        // Approve untuk limit open
        usdc.approve(address(executor), COLLATERAL + executionFee);

        // Open position
        uint256 orderId = executor.createLimitOpenOrder(
            "BTC",
            true,
            COLLATERAL,
            LEVERAGE,
            TRIGGER_PRICE_LONG // Entry: $90,000
        );
        vm.stopPrank();

        vm.startPrank(keeper);
        executor.executeLimitOpenOrder(
            orderId,
            LimitExecutor.SignedPrice({symbol: "BTC", price: TRIGGER_PRICE_LONG, timestamp: block.timestamp, signature: hex"00"})
        );
        vm.stopPrank();

        // Create TP
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        uint256 positionId = order.positionId;

        vm.startPrank(trader1);
        // FIXED: Approve untuk TP order
        usdc.approve(address(executor), executionFee);

        uint256 tpPrice = 100000e8; // TP at $100,000 (profit!)
        uint256 tpOrderId = executor.createLimitCloseOrder(positionId, tpPrice);
        vm.stopPrank();

        // Execute TP when price rises
        vm.startPrank(keeper);
        executor.executeLimitCloseOrder(
            tpOrderId,
            LimitExecutor.SignedPrice({
                symbol: "BTC",
                price: tpPrice, // Price hit $100,000!
                timestamp: block.timestamp,
                signature: hex"00"
            })
        );
        vm.stopPrank();

        // Verify TP executed
        LimitExecutor.Order memory tpOrder = executor.getOrder(tpOrderId);
        assertEq(uint8(tpOrder.status), uint8(LimitExecutor.OrderStatus.EXECUTED), "TP order should be EXECUTED");

        // Verify position closed
        PositionManager.Position memory position = positionManager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(PositionManager.PositionStatus.CLOSED), "Position should be CLOSED");
    }

    // ========================================
    // TEST 13: Execute Stop Loss (Long Position)
    // ========================================
    function testExecuteStopLoss_LongPosition() public {
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();

        // Approve untuk limit open
        usdc.approve(address(executor), COLLATERAL + executionFee);

        uint256 orderId = executor.createLimitOpenOrder(
            "BTC",
            true,
            COLLATERAL,
            LEVERAGE,
            TRIGGER_PRICE_LONG // Entry: $90,000
        );
        vm.stopPrank();

        vm.startPrank(keeper);
        executor.executeLimitOpenOrder(
            orderId,
            LimitExecutor.SignedPrice({symbol: "BTC", price: TRIGGER_PRICE_LONG, timestamp: block.timestamp, signature: hex"00"})
        );
        vm.stopPrank();

        // Create SL
        LimitExecutor.Order memory order = executor.getOrder(orderId);
        uint256 positionId = order.positionId;

        vm.startPrank(trader1);
        // FIXED: Approve untuk SL order
        usdc.approve(address(executor), executionFee);

        uint256 slPrice = 85000e8; // SL at $85,000 (cut loss)
        uint256 slOrderId = executor.createStopLossOrder(positionId, slPrice);
        vm.stopPrank();

        // Execute SL when price drops
        vm.startPrank(keeper);
        executor.executeStopLossOrder(
            slOrderId,
            LimitExecutor.SignedPrice({
                symbol: "BTC",
                price: slPrice, // Price dropped to $85,000!
                timestamp: block.timestamp,
                signature: hex"00"
            })
        );
        vm.stopPrank();

        // Verify SL executed
        LimitExecutor.Order memory slOrder = executor.getOrder(slOrderId);
        assertEq(uint8(slOrder.status), uint8(LimitExecutor.OrderStatus.EXECUTED), "SL order should be EXECUTED");

        // Verify position closed
        PositionManager.Position memory position = positionManager.getPosition(positionId);
        assertEq(uint8(position.status), uint8(PositionManager.PositionStatus.CLOSED), "Position should be CLOSED");
    }

    // ========================================
    // TEST 14: Get User Orders
    // ========================================
    function testGetUserOrders() public {
        vm.startPrank(trader1);
        uint256 executionFee = executor.executionFee();
        usdc.approve(address(executor), COLLATERAL * 3 + executionFee * 3);

        // Create 3 orders
        uint256 orderId1 = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);
        uint256 orderId2 = executor.createLimitOpenOrder("BTC", false, COLLATERAL, LEVERAGE, TRIGGER_PRICE_SHORT);
        uint256 orderId3 = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);

        vm.stopPrank();

        // Get user orders
        uint256[] memory userOrders = executor.getUserOrders(trader1);
        assertEq(userOrders.length, 3, "Should have 3 orders");
        assertEq(userOrders[0], orderId1, "First order ID mismatch");
        assertEq(userOrders[1], orderId2, "Second order ID mismatch");
        assertEq(userOrders[2], orderId3, "Third order ID mismatch");
    }

    // ========================================
    // TEST 15: Multiple Traders, Multiple Orders
    // ========================================
    function testMultipleTraders() public {
        uint256 executionFee = executor.executionFee();

        // Trader1 creates 2 orders
        vm.startPrank(trader1);
        usdc.approve(address(executor), COLLATERAL * 2 + executionFee * 2);
        uint256 t1Order1 = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);
        uint256 t1Order2 = executor.createLimitOpenOrder("BTC", false, COLLATERAL, LEVERAGE, TRIGGER_PRICE_SHORT);
        vm.stopPrank();

        // Trader2 creates 1 order
        vm.startPrank(trader2);
        usdc.approve(address(executor), COLLATERAL + executionFee);
        uint256 t2Order1 = executor.createLimitOpenOrder("BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG);
        vm.stopPrank();

        // Verify orders
        uint256[] memory t1Orders = executor.getUserOrders(trader1);
        uint256[] memory t2Orders = executor.getUserOrders(trader2);

        assertEq(t1Orders.length, 2, "Trader1 should have 2 orders");
        assertEq(t2Orders.length, 1, "Trader2 should have 1 order");

        assertEq(t1Orders[0], t1Order1, "Trader1 order 1 mismatch");
        assertEq(t1Orders[1], t1Order2, "Trader1 order 2 mismatch");
        assertEq(t2Orders[0], t2Order1, "Trader2 order 1 mismatch");
    }
}

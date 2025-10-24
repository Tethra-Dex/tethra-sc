// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LimitExecutorV2} from "../src/trading/LimitExecutorV2.sol";
import {PositionManager} from "../src/trading/PositionManager.sol";
import {RiskManager} from "../src/risk/RiskManager.sol";
import {TreasuryManager} from "../src/treasury/TreasuryManager.sol";
import {MockUSDC} from "../src/token/MockUSDC.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract LimitExecutorV2Test is Test {
    using MessageHashUtils for bytes32;

    event BadDebtCovered(address indexed trader, uint256 excessLoss, uint256 totalLoss);

    LimitExecutorV2 public executor;
    PositionManager public positionManager;
    RiskManager public riskManager;
    TreasuryManager public treasury;
    MockUSDC public usdc;

    address public keeper;
    uint256 public traderPk;
    address public trader;
    uint256 public backendSignerPk;
    address public backendSigner;

    uint256 constant INITIAL_BALANCE = 100_000e6; // 100k USDC with 6 decimals
    uint256 constant COLLATERAL = 1_000e6; // 1,000 USDC
    uint256 constant LEVERAGE = 10;
    uint256 constant TRIGGER_PRICE_LONG = 90_000e8; // price with 8 decimals

    function setUp() public {
        keeper = makeAddr("keeper");

        traderPk = 0xA11CE;
        trader = vm.addr(traderPk);

        backendSignerPk = 0xBEEF;
        backendSigner = vm.addr(backendSignerPk);

        usdc = new MockUSDC(10_000_000);
        riskManager = new RiskManager();
        positionManager = new PositionManager();

        address stakingRewards = makeAddr("stakingRewards");
        address protocolTreasury = makeAddr("protocolTreasury");
        treasury = new TreasuryManager(address(usdc), stakingRewards, protocolTreasury);

        riskManager.setAssetConfig(
            "BTC",
            true,
            25, // max leverage
            5_000_000e6, // max position size
            20_000_000e6, // max open interest
            7500 // liquidation threshold (75%)
        );

        executor = new LimitExecutorV2(
            address(usdc), address(riskManager), address(positionManager), address(treasury), keeper, backendSigner
        );

        positionManager.grantRole(positionManager.EXECUTOR_ROLE(), address(executor));
        treasury.grantRole(treasury.EXECUTOR_ROLE(), address(executor));

        usdc.transfer(trader, INITIAL_BALANCE);
        usdc.transfer(address(treasury), 5_000_000e6);

        vm.startPrank(trader);
        usdc.approve(address(executor), type(uint256).max);
        vm.stopPrank();

        vm.label(trader, "Trader");
        vm.label(keeper, "Keeper");
        vm.label(address(executor), "LimitExecutorV2");
    }

    function testExecuteLimitOpenOrderPullsOnlyCollateral() public {
        (uint256 orderId,, uint256 executionPrice) = _openLimitOrder();

        LimitExecutorV2.Order memory order = executor.getOrder(orderId);
        assertEq(order.trader, trader, "Trader mismatch");
        assertEq(order.collateral, COLLATERAL, "Collateral mismatch");
        assertEq(order.triggerPrice, TRIGGER_PRICE_LONG, "Trigger price mismatch");
        assertEq(uint8(order.status), uint8(LimitExecutorV2.OrderStatus.EXECUTED), "Order should be executed");
        assertGt(order.positionId, 0, "Position not created");

        PositionManager.Position memory position = positionManager.getPosition(order.positionId);
        assertEq(position.trader, trader, "Position trader mismatch");
        assertEq(position.entryPrice, executionPrice, "Entry price mismatch");
        assertEq(position.collateral, COLLATERAL, "Position collateral mismatch");
        assertEq(position.size, COLLATERAL * LEVERAGE, "Position size mismatch");

        // Collateral pulled, no trading fee on open
        assertEq(usdc.balanceOf(trader), INITIAL_BALANCE - COLLATERAL, "Trader should only pay collateral");
        assertEq(usdc.balanceOf(address(treasury)), 5_000_000e6 + COLLATERAL, "Treasury should receive collateral");
        assertEq(treasury.totalFees(), 0, "No trading fee should be collected on open");
    }

    function testLimitCloseOrderChargesTradingFeeOnClose() public {
        (uint256 openOrderId, uint256 positionId, uint256 entryPrice) = _openLimitOrder();
        assertGt(openOrderId, 0);
        assertGt(positionId, 0);
        assertEq(entryPrice, TRIGGER_PRICE_LONG - 100e8, "Unexpected execution price");

        uint256 nonce = executor.getUserCurrentNonce(trader);
        uint256 takeProfitPrice = TRIGGER_PRICE_LONG + 5_000e8;
        uint256 expiresAt = block.timestamp + 3 days;

        bytes memory userSignature = _signLimitCloseOrder(trader, positionId, takeProfitPrice, nonce, expiresAt);

        vm.prank(keeper);
        uint256 closeOrderId =
            executor.createLimitCloseOrder(trader, positionId, takeProfitPrice, nonce, expiresAt, userSignature);

        vm.warp(block.timestamp + 1 hours);
        LimitExecutorV2.SignedPrice memory signedPrice = _signedPrice("BTC", takeProfitPrice, block.timestamp);

        PositionManager.Position memory position = positionManager.getPosition(positionId);
        int256 expectedPnl = positionManager.calculatePnL(positionId, signedPrice.price);
        uint256 tradingFee = (position.size * executor.tradingFeeBps()) / 100000;

        uint256 traderBalanceBefore = usdc.balanceOf(trader);
        uint256 treasuryFeesBefore = treasury.totalFees();

        vm.prank(keeper);
        executor.executeLimitCloseOrder(closeOrderId, signedPrice);

        LimitExecutorV2.Order memory order = executor.getOrder(closeOrderId);
        assertEq(uint8(order.status), uint8(LimitExecutorV2.OrderStatus.EXECUTED), "Close order should be executed");

        PositionManager.Position memory updatedPosition = positionManager.getPosition(positionId);
        assertEq(uint8(updatedPosition.status), uint8(PositionManager.PositionStatus.CLOSED), "Position not closed");

        int256 netAmount = int256(position.collateral) + expectedPnl - int256(tradingFee);
        assertGt(netAmount, 0, "Expected positive refund");

        uint256 expectedRefund = uint256(netAmount);

        assertEq(usdc.balanceOf(trader) - traderBalanceBefore, expectedRefund, "Trader refund after close mismatch");

        // Fee split: 20% to relayer, 80% to treasury
        uint256 expectedTreasuryFee = (tradingFee * 8000) / 10000;
        assertEq(treasury.totalFees() - treasuryFeesBefore, expectedTreasuryFee, "Trading fee not accounted for in treasury");
    }

    function testStopLossCapsLossAtNinetyNinePercent() public {
        (, uint256 positionId,) = _openLimitOrder();

        uint256 nonce = executor.getUserCurrentNonce(trader);
        uint256 stopPrice = TRIGGER_PRICE_LONG - 10_000e8;
        uint256 expiresAt = block.timestamp + 7 days;

        bytes memory userSignature = _signStopLossOrder(trader, positionId, stopPrice, nonce, expiresAt);

        vm.prank(keeper);
        uint256 stopOrderId =
            executor.createStopLossOrder(trader, positionId, stopPrice, nonce, expiresAt, userSignature);

        vm.warp(block.timestamp + 2 hours);
        LimitExecutorV2.SignedPrice memory signedPrice = _signedPrice("BTC", 1e8, block.timestamp);

        PositionManager.Position memory position = positionManager.getPosition(positionId);
        int256 pnl = positionManager.calculatePnL(positionId, signedPrice.price);
        int256 maxAllowedLoss = -int256((position.collateral * 9900) / 10000);
        uint256 tradingFee = (position.size * executor.tradingFeeBps()) / 100000;
        int256 cappedPnl = pnl < maxAllowedLoss ? maxAllowedLoss : pnl;

        uint256 traderBalanceBefore = usdc.balanceOf(trader);
        uint256 treasuryFeesBefore = treasury.totalFees();
        uint256 collateralRefundedBefore = treasury.totalCollateralRefunded();

        if (pnl < maxAllowedLoss) {
            uint256 excessLoss = uint256(-pnl) - uint256(-maxAllowedLoss);
            vm.expectEmit(true, true, false, true, address(executor));
            emit BadDebtCovered(trader, excessLoss, uint256(-pnl));
        }

        vm.prank(keeper);
        executor.executeStopLossOrder(stopOrderId, signedPrice);

        LimitExecutorV2.Order memory order = executor.getOrder(stopOrderId);
        assertEq(uint8(order.status), uint8(LimitExecutorV2.OrderStatus.EXECUTED), "Stop loss not executed");

        int256 netAmount = int256(position.collateral) + cappedPnl - int256(tradingFee);
        uint256 expectedRefund = netAmount > 0 ? uint256(netAmount) : 0;

        assertEq(usdc.balanceOf(trader) - traderBalanceBefore, expectedRefund, "Refund should match capped loss logic");

        assertEq(
            treasury.totalCollateralRefunded() - collateralRefundedBefore,
            expectedRefund,
            "Treasury refund accounting mismatch"
        );

        // Fee split: 20% to relayer, 80% to treasury
        uint256 expectedTreasuryFee = (tradingFee * 8000) / 10000;
        assertEq(treasury.totalFees() - treasuryFeesBefore, expectedTreasuryFee, "Trading fee not collected on stop loss");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _openLimitOrder() internal returns (uint256 orderId, uint256 positionId, uint256 executionPrice) {
        uint256 expiresAt = block.timestamp + 1 days;
        uint256 nonce = executor.getUserCurrentNonce(trader);
        bytes memory userSignature =
            _signLimitOpenOrder(trader, true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG, nonce, expiresAt);

        vm.prank(keeper);
        orderId = executor.createLimitOpenOrder(
            trader, "BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG, nonce, expiresAt, userSignature
        );

        LimitExecutorV2.SignedPrice memory signedPrice =
            _signedPrice("BTC", TRIGGER_PRICE_LONG - 100e8, block.timestamp);

        uint256 traderBalanceBefore = usdc.balanceOf(trader);

        vm.prank(keeper);
        executor.executeLimitOpenOrder(orderId, signedPrice);

        assertEq(traderBalanceBefore - usdc.balanceOf(trader), COLLATERAL, "Only collateral should be debited on open");

        positionId = executor.getOrder(orderId).positionId;
        executionPrice = signedPrice.price;
    }

    function _signLimitOpenOrder(
        address orderTrader,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        uint256 nonce,
        uint256 expiresAt
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                orderTrader, "BTC", isLong, collateral, leverage, triggerPrice, nonce, expiresAt, address(executor)
            )
        );

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signLimitCloseOrder(
        address orderTrader,
        uint256 positionId,
        uint256 triggerPrice,
        uint256 nonce,
        uint256 expiresAt
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(orderTrader, positionId, triggerPrice, nonce, expiresAt, address(executor))
        );

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signStopLossOrder(
        address orderTrader,
        uint256 positionId,
        uint256 triggerPrice,
        uint256 nonce,
        uint256 expiresAt
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(orderTrader, positionId, triggerPrice, nonce, expiresAt, address(executor), "STOP_LOSS")
        );

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signedPrice(string memory symbol, uint256 price, uint256 timestamp)
        internal
        view
        returns (LimitExecutorV2.SignedPrice memory)
    {
        bytes32 priceHash = keccak256(abi.encodePacked(symbol, price, timestamp));
        bytes32 ethSigned = priceHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendSignerPk, ethSigned);
        bytes memory sig = abi.encodePacked(r, s, v);

        return LimitExecutorV2.SignedPrice({symbol: symbol, price: price, timestamp: timestamp, signature: sig});
    }
}

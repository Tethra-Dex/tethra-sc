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
    uint256 constant EXEC_FEE_CAP = 150_000; // 0.15 USDC

    function setUp() public {
        // Deterministic actors for signing
        keeper = makeAddr("keeper");

        traderPk = 0xA11CE;
        trader = vm.addr(traderPk);

        backendSignerPk = 0xBEEF;
        backendSigner = vm.addr(backendSignerPk);

        // Deploy core dependencies
        usdc = new MockUSDC(10_000_000); // mint 10M USDC
        riskManager = new RiskManager();
        positionManager = new PositionManager();

        address stakingRewards = makeAddr("stakingRewards");
        address protocolTreasury = makeAddr("protocolTreasury");
        treasury = new TreasuryManager(address(usdc), stakingRewards, protocolTreasury);

        // Configure risk manager for BTC trading
        riskManager.setAssetConfig(
            "BTC",
            true,
            25, // max leverage
            5_000_000e6, // max position size
            20_000_000e6, // max open interest
            7500 // liquidation threshold (75%)
        );

        // Deploy executor
        executor = new LimitExecutorV2(
            address(usdc), address(riskManager), address(positionManager), address(treasury), keeper, backendSigner
        );

        // Grant executor permissions
        positionManager.grantRole(positionManager.EXECUTOR_ROLE(), address(executor));
        treasury.grantRole(treasury.EXECUTOR_ROLE(), address(executor));

        // Fund trader and treasury
        usdc.transfer(trader, INITIAL_BALANCE);
        usdc.transfer(address(treasury), 5_000_000e6);

        // Trader pre-approves USDC for executor (needed at execution time)
        vm.startPrank(trader);
        usdc.approve(address(executor), type(uint256).max);
        vm.stopPrank();

        // Label for debugging
        vm.label(trader, "Trader");
        vm.label(keeper, "Keeper");
        vm.label(address(executor), "LimitExecutorV2");
    }

    function testKeeperCreatesAndExecutesLimitOpenOrderWithDynamicFee() public {
        uint256 expiresAt = block.timestamp + 1 days;
        uint256 nonce = executor.getUserCurrentNonce(trader);
        bytes memory userSignature =
            _signLimitOpenOrder(trader, true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG, EXEC_FEE_CAP, nonce, expiresAt);

        // Keeper submits order on behalf of trader
        vm.prank(keeper);
        uint256 orderId = executor.createLimitOpenOrder(
            trader, "BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG, EXEC_FEE_CAP, nonce, expiresAt, userSignature
        );

        LimitExecutorV2.Order memory order = executor.getOrder(orderId);
        assertEq(order.trader, trader, "Trader mismatch");
        assertEq(order.maxExecutionFee, EXEC_FEE_CAP, "Max execution fee stored incorrectly");
        assertEq(order.executionFeePaid, 0, "Execution fee should start at zero");
        assertEq(uint8(order.status), uint8(LimitExecutorV2.OrderStatus.PENDING), "Order should be pending");

        // Backend signs price payload
        uint256 executionFeePaid = 120_000; // 0.12 USDC
        LimitExecutorV2.SignedPrice memory signedPrice = _signedPrice(
            "BTC",
            TRIGGER_PRICE_LONG - 500e8, // price below trigger to satisfy long condition
            block.timestamp
        );

        uint256 traderBalanceBefore = usdc.balanceOf(trader);
        uint256 keeperBalanceBefore = usdc.balanceOf(keeper);
        uint256 treasuryBalanceBefore = usdc.balanceOf(address(treasury));

        // Execute order
        vm.prank(keeper);
        executor.executeLimitOpenOrder(orderId, signedPrice, executionFeePaid);

        order = executor.getOrder(orderId);
        assertEq(uint8(order.status), uint8(LimitExecutorV2.OrderStatus.EXECUTED), "Order status not updated");
        assertEq(order.executionFeePaid, executionFeePaid, "Execution fee paid mismatch");
        assertGt(order.positionId, 0, "Position not created");

        uint256 positionSize = COLLATERAL * LEVERAGE;
        uint256 tradingFee = (positionSize * executor.tradingFeeBps()) / 10_000;
        uint256 totalCost = COLLATERAL + tradingFee + executionFeePaid;

        assertEq(
            traderBalanceBefore - usdc.balanceOf(trader),
            totalCost,
            "Trader should pay collateral + trading + execution fee"
        );
        assertEq(
            usdc.balanceOf(address(treasury)) - treasuryBalanceBefore,
            totalCost - executionFeePaid,
            "Treasury should retain collateral + trading fee"
        );
        assertEq(usdc.balanceOf(keeper) - keeperBalanceBefore, executionFeePaid, "Keeper should receive execution fee");
        assertEq(treasury.totalExecutionFees(), 0, "Execution fee pool should be zero after payout");
    }

    function testExecuteLimitOpenOrderRevertsWhenFeeExceedsMax() public {
        uint256 expiresAt = block.timestamp + 1 days;
        uint256 nonce = executor.getUserCurrentNonce(trader);
        bytes memory userSignature =
            _signLimitOpenOrder(trader, true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG, EXEC_FEE_CAP, nonce, expiresAt);

        vm.prank(keeper);
        uint256 orderId = executor.createLimitOpenOrder(
            trader, "BTC", true, COLLATERAL, LEVERAGE, TRIGGER_PRICE_LONG, EXEC_FEE_CAP, nonce, expiresAt, userSignature
        );

        LimitExecutorV2.SignedPrice memory signedPrice =
            _signedPrice("BTC", TRIGGER_PRICE_LONG - 100e8, block.timestamp);

        uint256 excessiveFee = EXEC_FEE_CAP + 1;
        vm.prank(keeper);
        vm.expectRevert("Execution fee above max");
        executor.executeLimitOpenOrder(orderId, signedPrice, excessiveFee);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _signLimitOpenOrder(
        address orderTrader,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        uint256 maxExecutionFee,
        uint256 nonce,
        uint256 expiresAt
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                orderTrader,
                "BTC",
                isLong,
                collateral,
                leverage,
                triggerPrice,
                maxExecutionFee,
                nonce,
                expiresAt,
                address(executor)
            )
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

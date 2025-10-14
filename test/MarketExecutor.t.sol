// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/trading/MarketExecutor.sol";
import "../src/trading/PositionManager.sol";
import "../src/risk/RiskManager.sol";
import "../src/token/MockUSDC.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract TreasuryManagerMock is ITreasuryManager {
    IERC20 public immutable usdc;

    uint256 public totalFeesCollected;
    uint256 public totalRefunded;
    uint256 public totalDistributed;

    mapping(address => uint256) public feesByTrader;
    mapping(address => uint256) public refundsByTrader;
    mapping(address => uint256) public distributionByAccount;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function fund(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "fund transfer failed");
    }

    function collectFee(address from, uint256 amount) external override {
        totalFeesCollected += amount;
        feesByTrader[from] += amount;
    }

    function distributeProfit(address to, uint256 amount) external override {
        totalDistributed += amount;
        distributionByAccount[to] += amount;
        require(usdc.transfer(to, amount), "profit transfer failed");
    }

    function refundCollateral(address to, uint256 amount) external override {
        totalRefunded += amount;
        refundsByTrader[to] += amount;
        require(usdc.transfer(to, amount), "refund transfer failed");
    }
}

contract MarketExecutorHarness is MarketExecutor {
    constructor(
        address _usdc,
        address _riskManager,
        address _positionManager,
        address _treasuryManager,
        address _backendSigner
    ) MarketExecutor(_usdc, _riskManager, _positionManager, _treasuryManager, _backendSigner) {}

    function exposeSettle(address trader, uint256 collateral, int256 pnl, uint256 tradingFee) external {
        _settleIsolatedMargin(trader, collateral, pnl, tradingFee);
    }
}

contract MarketExecutorTest is Test {
    using MessageHashUtils for bytes32;

    event BadDebtCovered(address indexed trader, uint256 excessLoss, uint256 totalLoss);
    event FeesUpdated(uint256 tradingFeeBps, uint256 liquidationFeeBps);

    MarketExecutorHarness public executor;
    PositionManager public positionManager;
    RiskManager public riskManager;
    TreasuryManagerMock public treasury;
    MockUSDC public usdc;

    address public trader;
    address public liquidator;

    uint256 public backendSignerPK = 0xABC123;
    address public backendSigner;

    uint256 constant INITIAL_BALANCE = 1_000_000e6;
    uint256 constant COLLATERAL = 1_000e6;
    uint256 constant LEVERAGE = 10;
    uint256 constant BTC_PRICE = 50_000e8;

    function setUp() public {
        trader = makeAddr("trader");
        liquidator = makeAddr("liquidator");
        backendSigner = vm.addr(backendSignerPK);

        usdc = new MockUSDC(10_000_000);
        riskManager = new RiskManager();
        positionManager = new PositionManager();
        treasury = new TreasuryManagerMock(IERC20(address(usdc)));

        executor = new MarketExecutorHarness(
            address(usdc), address(riskManager), address(positionManager), address(treasury), backendSigner
        );

        positionManager.grantRole(positionManager.EXECUTOR_ROLE(), address(executor));

        riskManager.setAssetConfig("BTC", true, 20, 100_000e6, 1_000_000e6, 7500);

        usdc.mint(trader, INITIAL_BALANCE);
        usdc.mint(liquidator, INITIAL_BALANCE);

        vm.prank(trader);
        usdc.approve(address(executor), type(uint256).max);

        vm.prank(liquidator);
        usdc.approve(address(executor), type(uint256).max);

        usdc.approve(address(treasury), type(uint256).max);
        treasury.fund(5_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Open position tests
    // -------------------------------------------------------------------------

    function testOpenMarketPosition_LongPullsCollateralOnly() public {
        MarketExecutor.SignedPrice memory signedPrice = _signedPrice("BTC", BTC_PRICE, block.timestamp);

        uint256 traderBalanceBefore = usdc.balanceOf(trader);
        uint256 treasuryBalanceBefore = usdc.balanceOf(address(treasury));

        vm.prank(trader);
        uint256 positionId = executor.openMarketPosition("BTC", true, COLLATERAL, LEVERAGE, signedPrice);

        assertEq(positionId, 1);
        assertEq(traderBalanceBefore - usdc.balanceOf(trader), COLLATERAL, "Trader should pay only collateral");
        assertEq(
            usdc.balanceOf(address(treasury)) - treasuryBalanceBefore,
            COLLATERAL,
            "Treasury should receive collateral"
        );

        PositionManager.Position memory position = positionManager.getPosition(positionId);
        assertEq(position.trader, trader);
        assertEq(position.entryPrice, BTC_PRICE);
        assertEq(position.size, COLLATERAL * LEVERAGE);
        assertTrue(position.isLong);
    }

    function testOpenMarketPosition_InvalidSignature() public {
        bytes32 messageHash = keccak256(abi.encodePacked("BTC", BTC_PRICE, block.timestamp));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEADBEEF, ethSignedMessageHash);

        MarketExecutor.SignedPrice memory signedPrice = MarketExecutor.SignedPrice({
            symbol: "BTC",
            price: BTC_PRICE,
            timestamp: block.timestamp,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert("MarketExecutor: Invalid signature");
        vm.prank(trader);
        executor.openMarketPosition("BTC", true, COLLATERAL, LEVERAGE, signedPrice);
    }

    function testOpenMarketPosition_ExpiredPrice() public {
        vm.warp(block.timestamp + 10 minutes);
        uint256 oldTimestamp = block.timestamp - 6 minutes;
        MarketExecutor.SignedPrice memory signedPrice = _signedPrice("BTC", BTC_PRICE, oldTimestamp);

        vm.expectRevert("MarketExecutor: Price expired");
        vm.prank(trader);
        executor.openMarketPosition("BTC", true, COLLATERAL, LEVERAGE, signedPrice);
    }

    function testOpenMarketPosition_FutureTimestamp() public {
        uint256 futureTimestamp = block.timestamp + 1 hours;
        MarketExecutor.SignedPrice memory signedPrice = _signedPrice("BTC", BTC_PRICE, futureTimestamp);

        vm.expectRevert("MarketExecutor: Price timestamp in future");
        vm.prank(trader);
        executor.openMarketPosition("BTC", true, COLLATERAL, LEVERAGE, signedPrice);
    }

    function testOpenMarketPosition_InvalidLeverage() public {
        MarketExecutor.SignedPrice memory signedPrice = _signedPrice("BTC", BTC_PRICE, block.timestamp);

        vm.expectRevert("MarketExecutor: Trade validation failed");
        vm.prank(trader);
        executor.openMarketPosition("BTC", true, COLLATERAL, 100, signedPrice);
    }

    // -------------------------------------------------------------------------
    // Settlement unit tests (via harness)
    // -------------------------------------------------------------------------

    function testSettlementHandlesProfit() public {
        uint256 collateral = 1_000e6;
        int256 pnl = int256(500e6);
        uint256 tradingFee = 50e5; // 0.5 USDC

        uint256 traderBalanceBefore = usdc.balanceOf(trader);
        uint256 treasuryBalanceBefore = usdc.balanceOf(address(treasury));

        executor.exposeSettle(trader, collateral, pnl, tradingFee);

        uint256 expectedRefund = collateral + uint256(pnl) - tradingFee;
        assertEq(usdc.balanceOf(trader) - traderBalanceBefore, expectedRefund, "Trader refund mismatch");
        assertEq(treasury.totalFeesCollected(), tradingFee, "Trading fee accounting mismatch");
        assertEq(
            treasuryBalanceBefore - usdc.balanceOf(address(treasury)),
            expectedRefund,
            "Treasury outflow mismatch"
        );
    }

    function testSettlementCapsLossAtNinetyNinePercent() public {
        uint256 collateral = 1_000e6;
        int256 pnl = -int256(5_000_000e6); // Massive loss
        uint256 tradingFee = 50e5;

        uint256 traderBalanceBefore = usdc.balanceOf(trader);

        vm.expectEmit(true, false, false, false, address(executor));
        emit BadDebtCovered(trader, 0, 0);

        executor.exposeSettle(trader, collateral, pnl, tradingFee);

        uint256 refundReceived = usdc.balanceOf(trader) - traderBalanceBefore;
        uint256 maxRefund = (collateral * 100) / 10000; // 1%

        assertGt(refundReceived, 0, "Refund should remain positive");
        assertLe(refundReceived, maxRefund, "Refund should be capped near 1%");
        assertEq(treasury.totalFeesCollected(), tradingFee, "Trading fee should still be collected");
    }

    // -------------------------------------------------------------------------
    // Fee management
    // -------------------------------------------------------------------------

    function testUpdateFees() public {
        vm.expectEmit(false, false, false, true, address(executor));
        emit FeesUpdated(8, 120);

        executor.updateFees(8, 120);
        assertEq(executor.tradingFeeBps(), 8);
        assertEq(executor.liquidationFeeBps(), 120);
    }

    function testUpdateFees_TradingTooHigh() public {
        vm.expectRevert("MarketExecutor: Trading fee too high");
        executor.updateFees(101, 50);
    }

    function testUpdateFees_LiquidationTooHigh() public {
        vm.expectRevert("MarketExecutor: Liquidation fee too high");
        executor.updateFees(5, 501);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _signedPrice(string memory symbol, uint256 price, uint256 timestamp)
        internal
        view
        returns (MarketExecutor.SignedPrice memory)
    {
        bytes32 messageHash = keccak256(abi.encodePacked(symbol, price, timestamp));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendSignerPK, ethSignedMessageHash);

        return MarketExecutor.SignedPrice({
            symbol: symbol,
            price: price,
            timestamp: timestamp,
            signature: abi.encodePacked(r, s, v)
        });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IRiskManager {
    function validateTrade(address trader, string calldata symbol, uint256 leverage, uint256 collateral, bool isLong)
        external
        view
        returns (bool);

    function shouldLiquidate(
        uint256 positionId,
        uint256 currentPrice,
        uint256 collateral,
        uint256 size,
        uint256 entryPrice,
        bool isLong
    ) external view returns (bool);
}

interface IPositionManager {
    function createPosition(
        address trader,
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 entryPrice
    ) external returns (uint256 positionId);

    function closePosition(uint256 positionId, uint256 exitPrice) external returns (int256 pnl);

    function liquidatePosition(uint256 positionId, uint256 liquidationPrice) external;

    function getPosition(uint256 positionId)
        external
        view
        returns (
            uint256 id,
            address trader,
            string memory symbol,
            bool isLong,
            uint256 collateral,
            uint256 size,
            uint256 leverage,
            uint256 entryPrice,
            uint256 openTimestamp,
            uint8 status
        );
}

interface ITreasuryManager {
    function collectFee(address from, uint256 amount) external;
    function collectFeeWithRelayerSplit(address from, address relayer, uint256 totalFeeAmount) external;
    function distributeProfit(address to, uint256 amount) external;
    function refundCollateral(address to, uint256 amount) external;
}

/**
 * @title MarketExecutor
 * @notice Executes instant market orders with backend-signed prices
 * @dev Traders pay gas (as USDC via paymaster), backend signs prices off-chain
 */
contract MarketExecutor is AccessControl, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant BACKEND_SIGNER_ROLE = keccak256("BACKEND_SIGNER_ROLE");

    IERC20 public immutable usdc;
    IRiskManager public riskManager;
    IPositionManager public positionManager;
    ITreasuryManager public treasuryManager;

    // Fee structure (in basis points, 1 bp = 0.01%)
    uint256 public tradingFeeBps = 5; // 0.05%
    uint256 public liquidationFeeBps = 50; // 0.5%

    // Price signature validity window (5 minutes)
    uint256 public constant PRICE_VALIDITY_WINDOW = 5 minutes;

    // Nonce tracking to prevent replay attacks
    mapping(address => uint256) public nonces;

    // Meta-transaction nonces for gasless transactions
    mapping(address => uint256) public metaNonces;

    // Events
    event MarketOrderExecuted(
        uint256 indexed positionId,
        address indexed trader,
        string symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 price
    );

    event PositionClosedMarket(
        uint256 indexed positionId, address indexed trader, uint256 exitPrice, int256 pnl, uint256 fee
    );

    event PositionLiquidatedMarket(
        uint256 indexed positionId, address indexed liquidator, uint256 liquidationPrice, uint256 liquidationFee
    );

    event FeesUpdated(uint256 tradingFeeBps, uint256 liquidationFeeBps);

    event MetaTransactionExecuted(address indexed userAddress, address indexed relayerAddress, uint256 nonce);
    event BadDebtCovered(address indexed trader, uint256 excessLoss, uint256 totalLoss);
    event TotalLiquidation(address indexed trader, uint256 collateral);

    /**
     * @notice Signed price data structure
     * @dev Backend signs this data off-chain
     */
    struct SignedPrice {
        string symbol;
        uint256 price; // Price with 8 decimals
        uint256 timestamp; // When price was signed
        bytes signature; // Backend signature
    }

    constructor(
        address _usdc,
        address _riskManager,
        address _positionManager,
        address _treasuryManager,
        address _backendSigner
    ) {
        require(_usdc != address(0), "MarketExecutor: Invalid USDC");
        require(_riskManager != address(0), "MarketExecutor: Invalid RiskManager");
        require(_positionManager != address(0), "MarketExecutor: Invalid PositionManager");
        require(_treasuryManager != address(0), "MarketExecutor: Invalid TreasuryManager");
        require(_backendSigner != address(0), "MarketExecutor: Invalid signer");

        usdc = IERC20(_usdc);
        riskManager = IRiskManager(_riskManager);
        positionManager = IPositionManager(_positionManager);
        treasuryManager = ITreasuryManager(_treasuryManager);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BACKEND_SIGNER_ROLE, _backendSigner);
    }

    /**
     * @notice Execute a market order to open a position
     * @param symbol Asset symbol (BTC, ETH, etc)
     * @param isLong True for long, false for short
     * @param collateral Collateral amount in USDC (6 decimals)
     * @param leverage Leverage multiplier
     * @param signedPrice Backend-signed price data
     */
    function openMarketPosition(
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        SignedPrice calldata signedPrice
    ) external nonReentrant returns (uint256 positionId) {
        // Verify price signature and freshness
        _verifySignedPrice(signedPrice);

        // Validate trade parameters via RiskManager
        require(
            riskManager.validateTrade(msg.sender, symbol, leverage, collateral, isLong),
            "MarketExecutor: Trade validation failed"
        );

        // Calculate trading fee
        uint256 positionSize = collateral * leverage;
        uint256 fee = (positionSize * tradingFeeBps) / 100000;

        // Collect collateral + fee from trader
        require(usdc.transferFrom(msg.sender, address(treasuryManager), collateral), "MarketExecutor: Transfer failed");

        // Collect fee to treasury
        // treasuryManager.collectFee(msg.sender, fee);

        // Create position via PositionManager
        positionId = positionManager.createPosition(msg.sender, symbol, isLong, collateral, leverage, signedPrice.price);

        emit MarketOrderExecuted(positionId, msg.sender, symbol, isLong, collateral, leverage, signedPrice.price);
    }

    /**
     * @notice Execute a market order via meta-transaction (for gasless trading)
     * @param trader The actual trader address (from AA wallet)
     * @param symbol Asset symbol (BTC, ETH, etc)
     * @param isLong True for long, false for short
     * @param collateral Collateral amount in USDC (6 decimals)
     * @param leverage Leverage multiplier
     * @param signedPrice Backend-signed price data
     * @param userSignature Signature from the trader approving this trade
     */
    function openMarketPositionMeta(
        address trader,
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        SignedPrice calldata signedPrice,
        bytes calldata userSignature
    ) external nonReentrant returns (uint256 positionId) {
        // Verify user signature
        bytes32 messageHash =
            keccak256(abi.encodePacked(trader, symbol, isLong, collateral, leverage, metaNonces[trader], address(this)));

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(userSignature);

        require(signer == trader, "MarketExecutor: Invalid user signature");

        // Increment nonce to prevent replay
        metaNonces[trader]++;

        // Verify price signature and freshness
        _verifySignedPrice(signedPrice);

        // Validate trade parameters via RiskManager
        require(
            riskManager.validateTrade(trader, symbol, leverage, collateral, isLong),
            "MarketExecutor: Trade validation failed"
        );

        // Calculate trading fee
        uint256 positionSize = collateral * leverage;
        // uint256 fee = (positionSize * tradingFeeBps) / 10000;

        // Collect collateral + fee from TRADER (not relayer!)
        require(usdc.transferFrom(trader, address(treasuryManager), collateral), "MarketExecutor: Transfer failed");

        // Collect fee to treasury
        // treasuryManager.collectFee(trader, fee);

        // Create position via PositionManager (use trader address, not msg.sender)
        positionId = positionManager.createPosition(trader, symbol, isLong, collateral, leverage, signedPrice.price);

        emit MetaTransactionExecuted(trader, msg.sender, metaNonces[trader] - 1);
        emit MarketOrderExecuted(positionId, trader, symbol, isLong, collateral, leverage, signedPrice.price);
    }

    /**
     * @notice Close a position at market price
     * @param positionId Position ID to close
     * @param signedPrice Backend-signed price data
     */
    function closeMarketPosition(uint256 positionId, SignedPrice calldata signedPrice) external nonReentrant {
        // Get position details
        (, address trader, string memory symbol, bool isLong, uint256 collateral, uint256 size,,,, uint8 status) =
            positionManager.getPosition(positionId);

        require(trader == msg.sender, "MarketExecutor: Not position owner");
        require(status == 0, "MarketExecutor: Position not open"); // 0 = OPEN
        require(keccak256(bytes(symbol)) == keccak256(bytes(signedPrice.symbol)), "MarketExecutor: Symbol mismatch");

        // Verify price signature
        _verifySignedPrice(signedPrice);

        // Close position and get PnL
        int256 pnl = positionManager.closePosition(positionId, signedPrice.price);

        // Calculate trading fee
        uint256 fee = (size * tradingFeeBps) / 100000;

        // ✅ ISOLATED MARGIN SETTLEMENT with 99% loss cap (msg.sender is the relayer)
        _settleIsolatedMargin(trader, collateral, pnl, fee, msg.sender);

        emit PositionClosedMarket(positionId, trader, signedPrice.price, pnl, fee);
    }

    /**
     * @notice Close a position at market price via meta-transaction (for gasless trading)
     * @param trader The actual trader address (from AA wallet)
     * @param positionId Position ID to close
     * @param signedPrice Backend-signed price data
     * @param userSignature Signature from the trader approving this close
     */
    function closeMarketPositionMeta(
        address trader,
        uint256 positionId,
        SignedPrice calldata signedPrice,
        bytes calldata userSignature
    ) external nonReentrant {
        // Get position details first to get symbol for signature verification
        (, address positionTrader, string memory symbol, bool isLong, uint256 collateral, uint256 size,,,, uint8 status)
        = positionManager.getPosition(positionId);

        // Verify user signature
        bytes32 messageHash = keccak256(abi.encodePacked(trader, positionId, metaNonces[trader], address(this)));

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(userSignature);

        require(signer == trader, "MarketExecutor: Invalid user signature");

        // Increment nonce to prevent replay
        metaNonces[trader]++;

        // Verify trader owns the position
        require(positionTrader == trader, "MarketExecutor: Not position owner");
        require(status == 0, "MarketExecutor: Position not open");
        require(keccak256(bytes(symbol)) == keccak256(bytes(signedPrice.symbol)), "MarketExecutor: Symbol mismatch");

        // Verify price signature
        _verifySignedPrice(signedPrice);

        // Close position and get PnL
        int256 pnl = positionManager.closePosition(positionId, signedPrice.price);

        // Calculate trading fee
        uint256 fee = (size * tradingFeeBps) / 100000;

        // ✅ ISOLATED MARGIN SETTLEMENT with 99% loss cap (msg.sender is the relayer)
        _settleIsolatedMargin(trader, collateral, pnl, fee, msg.sender);

        emit MetaTransactionExecuted(trader, msg.sender, metaNonces[trader] - 1);
        emit PositionClosedMarket(positionId, trader, signedPrice.price, pnl, fee);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @param positionId Position ID to liquidate
     * @param signedPrice Backend-signed price data
     */
    function liquidatePosition(uint256 positionId, SignedPrice calldata signedPrice) external nonReentrant {
        // Get position details
        (
            ,
            address trader,
            string memory symbol,
            bool isLong,
            uint256 collateral,
            uint256 size,
            ,
            uint256 entryPrice,
            ,
            uint8 status
        ) = positionManager.getPosition(positionId);

        require(status == 0, "MarketExecutor: Position not open");
        require(keccak256(bytes(symbol)) == keccak256(bytes(signedPrice.symbol)), "MarketExecutor: Symbol mismatch");

        // Verify price signature
        _verifySignedPrice(signedPrice);

        // Check if position should be liquidated
        require(
            riskManager.shouldLiquidate(positionId, signedPrice.price, collateral, size, entryPrice, isLong),
            "MarketExecutor: Position not eligible for liquidation"
        );

        // Liquidate position
        positionManager.liquidatePosition(positionId, signedPrice.price);

        // Calculate liquidation fee (from remaining collateral)
        uint256 liquidationFee = (collateral * liquidationFeeBps) / 10000;

        // Distribute liquidation fee to liquidator
        treasuryManager.distributeProfit(msg.sender, liquidationFee);

        emit PositionLiquidatedMarket(positionId, msg.sender, signedPrice.price, liquidationFee);
    }

    /**
     * @notice Verify backend-signed price data
     * @param signedPrice Signed price structure
     *
     * NOTE: Price validation temporarily disabled for hackathon demo
     * TODO: Re-enable after fixing timestamp synchronization issues
     */
    function _verifySignedPrice(SignedPrice calldata signedPrice) internal view {
        // TEMPORARY: Skip validation for demo
        // Just check price is not zero
        require(signedPrice.price > 0, "MarketExecutor: Invalid price");

        // Original validation (commented out for now):
        require(block.timestamp <= signedPrice.timestamp + PRICE_VALIDITY_WINDOW, "MarketExecutor: Price expired");
        require(signedPrice.timestamp <= block.timestamp, "MarketExecutor: Price timestamp in future");
        bytes32 messageHash = keccak256(abi.encodePacked(signedPrice.symbol, signedPrice.price, signedPrice.timestamp));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(signedPrice.signature);
        require(hasRole(BACKEND_SIGNER_ROLE, signer), "MarketExecutor: Invalid signature");
    }

    /**
     * @notice Update fee parameters (admin only)
     * @param _tradingFeeBps New trading fee in basis points
     * @param _liquidationFeeBps New liquidation fee in basis points
     */
    function updateFees(uint256 _tradingFeeBps, uint256 _liquidationFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tradingFeeBps <= 100, "MarketExecutor: Trading fee too high"); // Max 1%
        require(_liquidationFeeBps <= 500, "MarketExecutor: Liquidation fee too high"); // Max 5%

        tradingFeeBps = _tradingFeeBps;
        liquidationFeeBps = _liquidationFeeBps;

        emit FeesUpdated(_tradingFeeBps, _liquidationFeeBps);
    }

    /**
     * @notice Update contract references (admin only)
     */
    function updateContracts(address _riskManager, address _positionManager, address _treasuryManager)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_riskManager != address(0)) riskManager = IRiskManager(_riskManager);
        if (_positionManager != address(0)) positionManager = IPositionManager(_positionManager);
        if (_treasuryManager != address(0)) treasuryManager = ITreasuryManager(_treasuryManager);
    }

    /**
     * @notice Settle position with isolated margin rules
     * @dev Max loss CAPPED at 99% of collateral
     * @dev Fee split: 0.01% to relayer, 0.04% to treasury
     */
    function _settleIsolatedMargin(address trader, uint256 collateral, int256 pnl, uint256 tradingFee, address relayer)
        internal
    {
        // ✅ CAP LOSS AT 99%
        int256 maxAllowedLoss = -int256((collateral * 9900) / 10000);

        int256 cappedPnl = pnl;

        if (pnl < maxAllowedLoss) {
            cappedPnl = maxAllowedLoss;
            uint256 excessLoss = uint256(-pnl) - uint256(-maxAllowedLoss);
            emit BadDebtCovered(trader, excessLoss, uint256(-pnl));
        }

        int256 netAmount = int256(collateral) + cappedPnl - int256(tradingFee);

        if (netAmount <= 0) {
            uint256 loss = uint256(-cappedPnl);

            if (loss >= collateral) {
                emit TotalLiquidation(trader, collateral);
            } else {
                uint256 remaining = collateral - loss;

                if (remaining >= tradingFee) {
                    treasuryManager.collectFeeWithRelayerSplit(trader, relayer, tradingFee);
                    uint256 refund = remaining - tradingFee;
                    if (refund > 0) {
                        treasuryManager.refundCollateral(trader, refund);
                    }
                } else {
                    if (remaining > 0) {
                        treasuryManager.refundCollateral(trader, remaining);
                    }
                }
            }
        } else {
            treasuryManager.collectFeeWithRelayerSplit(trader, relayer, tradingFee);
            treasuryManager.refundCollateral(trader, uint256(netAmount));
        }
    }
}

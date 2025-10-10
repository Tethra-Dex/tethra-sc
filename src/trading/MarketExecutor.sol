// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IRiskManager {
    function validateTrade(
        address trader,
        string calldata symbol,
        uint256 leverage,
        uint256 collateral,
        bool isLong
    ) external view returns (bool);
    
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
    
    function closePosition(
        uint256 positionId,
        uint256 exitPrice
    ) external returns (int256 pnl);
    
    function liquidatePosition(
        uint256 positionId,
        uint256 liquidationPrice
    ) external;
    
    function getPosition(uint256 positionId) external view returns (
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
    
    // Events
    event MarketOrderExecuted(
        uint256 indexed positionId,
        address indexed trader,
        string symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 price,
        uint256 fee
    );
    
    event PositionClosedMarket(
        uint256 indexed positionId,
        address indexed trader,
        uint256 exitPrice,
        int256 pnl,
        uint256 fee
    );
    
    event PositionLiquidatedMarket(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 liquidationPrice,
        uint256 liquidationFee
    );
    
    event FeesUpdated(uint256 tradingFeeBps, uint256 liquidationFeeBps);
    
    /**
     * @notice Signed price data structure
     * @dev Backend signs this data off-chain
     */
    struct SignedPrice {
        string symbol;
        uint256 price;        // Price with 8 decimals
        uint256 timestamp;    // When price was signed
        bytes signature;      // Backend signature
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
        uint256 fee = (positionSize * tradingFeeBps) / 10000;
        
        // Collect collateral + fee from trader
        require(
            usdc.transferFrom(msg.sender, address(treasuryManager), collateral + fee),
            "MarketExecutor: Transfer failed"
        );
        
        // Collect fee to treasury
        treasuryManager.collectFee(msg.sender, fee);
        
        // Create position via PositionManager
        positionId = positionManager.createPosition(
            msg.sender,
            symbol,
            isLong,
            collateral,
            leverage,
            signedPrice.price
        );
        
        emit MarketOrderExecuted(
            positionId,
            msg.sender,
            symbol,
            isLong,
            collateral,
            leverage,
            signedPrice.price,
            fee
        );
    }
    
    /**
     * @notice Close a position at market price
     * @param positionId Position ID to close
     * @param signedPrice Backend-signed price data
     */
    function closeMarketPosition(
        uint256 positionId,
        SignedPrice calldata signedPrice
    ) external nonReentrant {
        // Get position details
        (
            ,
            address trader,
            string memory symbol,
            bool isLong,
            uint256 collateral,
            uint256 size,
            ,
            ,
            ,
            uint8 status
        ) = positionManager.getPosition(positionId);
        
        require(trader == msg.sender, "MarketExecutor: Not position owner");
        require(status == 0, "MarketExecutor: Position not open"); // 0 = OPEN
        require(
            keccak256(bytes(symbol)) == keccak256(bytes(signedPrice.symbol)),
            "MarketExecutor: Symbol mismatch"
        );
        
        // Verify price signature
        _verifySignedPrice(signedPrice);
        
        // Close position and get PnL
        int256 pnl = positionManager.closePosition(positionId, signedPrice.price);
        
        // Calculate trading fee
        uint256 fee = (size * tradingFeeBps) / 10000;
        
        // Settlement logic
        if (pnl > 0) {
            // Profit: return collateral + profit - fee
            uint256 profit = uint256(pnl);
            require(profit > fee, "MarketExecutor: Profit less than fee");
            
            treasuryManager.refundCollateral(trader, collateral);
            treasuryManager.distributeProfit(trader, profit - fee);
            treasuryManager.collectFee(trader, fee);
        } else if (pnl < 0) {
            // Loss: return collateral - loss - fee
            uint256 loss = uint256(-pnl);
            require(collateral > loss + fee, "MarketExecutor: Loss exceeds collateral");
            
            treasuryManager.refundCollateral(trader, collateral - loss - fee);
            treasuryManager.collectFee(trader, fee);
        } else {
            // Break even: return collateral - fee
            require(collateral > fee, "MarketExecutor: Collateral less than fee");
            treasuryManager.refundCollateral(trader, collateral - fee);
            treasuryManager.collectFee(trader, fee);
        }
        
        emit PositionClosedMarket(positionId, trader, signedPrice.price, pnl, fee);
    }
    
    /**
     * @notice Liquidate an undercollateralized position
     * @param positionId Position ID to liquidate
     * @param signedPrice Backend-signed price data
     */
    function liquidatePosition(
        uint256 positionId,
        SignedPrice calldata signedPrice
    ) external nonReentrant {
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
        require(
            keccak256(bytes(symbol)) == keccak256(bytes(signedPrice.symbol)),
            "MarketExecutor: Symbol mismatch"
        );
        
        // Verify price signature
        _verifySignedPrice(signedPrice);
        
        // Check if position should be liquidated
        require(
            riskManager.shouldLiquidate(
                positionId,
                signedPrice.price,
                collateral,
                size,
                entryPrice,
                isLong
            ),
            "MarketExecutor: Position not eligible for liquidation"
        );
        
        // Liquidate position
        positionManager.liquidatePosition(positionId, signedPrice.price);
        
        // Calculate liquidation fee (from remaining collateral)
        uint256 liquidationFee = (collateral * liquidationFeeBps) / 10000;
        
        // Distribute liquidation fee to liquidator
        treasuryManager.distributeProfit(msg.sender, liquidationFee);
        
        emit PositionLiquidatedMarket(
            positionId,
            msg.sender,
            signedPrice.price,
            liquidationFee
        );
    }
    
    /**
     * @notice Verify backend-signed price data
     * @param signedPrice Signed price structure
     */
    function _verifySignedPrice(SignedPrice calldata signedPrice) internal view {
        // Check price freshness
        require(
            block.timestamp <= signedPrice.timestamp + PRICE_VALIDITY_WINDOW,
            "MarketExecutor: Price expired"
        );
        require(
            signedPrice.timestamp <= block.timestamp,
            "MarketExecutor: Price timestamp in future"
        );
        
        // Reconstruct message hash
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                signedPrice.symbol,
                signedPrice.price,
                signedPrice.timestamp
            )
        );
        
        // Get Ethereum signed message hash
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        
        // Recover signer from signature
        address signer = ethSignedMessageHash.recover(signedPrice.signature);
        
        // Verify signer has BACKEND_SIGNER_ROLE
        require(
            hasRole(BACKEND_SIGNER_ROLE, signer),
            "MarketExecutor: Invalid signature"
        );
    }
    
    /**
     * @notice Update fee parameters (admin only)
     * @param _tradingFeeBps New trading fee in basis points
     * @param _liquidationFeeBps New liquidation fee in basis points
     */
    function updateFees(
        uint256 _tradingFeeBps,
        uint256 _liquidationFeeBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tradingFeeBps <= 100, "MarketExecutor: Trading fee too high"); // Max 1%
        require(_liquidationFeeBps <= 500, "MarketExecutor: Liquidation fee too high"); // Max 5%
        
        tradingFeeBps = _tradingFeeBps;
        liquidationFeeBps = _liquidationFeeBps;
        
        emit FeesUpdated(_tradingFeeBps, _liquidationFeeBps);
    }
    
    /**
     * @notice Update contract references (admin only)
     */
    function updateContracts(
        address _riskManager,
        address _positionManager,
        address _treasuryManager
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_riskManager != address(0)) riskManager = IRiskManager(_riskManager);
        if (_positionManager != address(0)) positionManager = IPositionManager(_positionManager);
        if (_treasuryManager != address(0)) treasuryManager = ITreasuryManager(_treasuryManager);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PositionManager
 * @notice Central registry for all trading positions
 * @dev Tracks positions, calculates PnL, handles position lifecycle
 */
contract PositionManager is AccessControl, ReentrancyGuard {
    
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    
    enum PositionStatus { OPEN, CLOSED, LIQUIDATED }
    
    struct Position {
        uint256 id;
        address trader;
        string symbol;           // Asset symbol (BTC, ETH, etc)
        bool isLong;            // True for long, false for short
        uint256 collateral;     // Collateral in USDC (6 decimals)
        uint256 size;           // Position size = collateral * leverage (6 decimals)
        uint256 leverage;       // Leverage multiplier (e.g., 10 for 10x)
        uint256 entryPrice;     // Entry price (8 decimals)
        uint256 openTimestamp;  // When position was opened
        PositionStatus status;  // Current status
    }
    
    // Position ID counter
    uint256 public nextPositionId = 1;
    
    // Position ID => Position data
    mapping(uint256 => Position) public positions;
    
    // User address => array of position IDs
    mapping(address => uint256[]) public userPositions;
    
    // Events
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
    
    event PositionClosed(
        uint256 indexed positionId,
        uint256 exitPrice,
        int256 pnl
    );
    
    event PositionLiquidated(
        uint256 indexed positionId,
        uint256 liquidationPrice,
        address liquidator
    );
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
    }
    
    /**
     * @notice Create a new position
     * @param trader Address of the trader
     * @param symbol Asset symbol
     * @param isLong True for long, false for short
     * @param collateral Collateral amount in USDC
     * @param leverage Leverage multiplier
     * @param entryPrice Entry price (8 decimals)
     * @return positionId The ID of the created position
     */
    function createPosition(
        address trader,
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 entryPrice
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant returns (uint256 positionId) {
        require(trader != address(0), "PositionManager: Invalid trader");
        require(collateral > 0, "PositionManager: Invalid collateral");
        require(leverage > 0, "PositionManager: Invalid leverage");
        require(entryPrice > 0, "PositionManager: Invalid price");
        
        positionId = nextPositionId++;
        uint256 size = collateral * leverage;
        
        positions[positionId] = Position({
            id: positionId,
            trader: trader,
            symbol: symbol,
            isLong: isLong,
            collateral: collateral,
            size: size,
            leverage: leverage,
            entryPrice: entryPrice,
            openTimestamp: block.timestamp,
            status: PositionStatus.OPEN
        });
        
        userPositions[trader].push(positionId);
        
        emit PositionOpened(
            positionId,
            trader,
            symbol,
            isLong,
            collateral,
            size,
            leverage,
            entryPrice
        );
    }
    
    /**
     * @notice Close a position
     * @param positionId Position ID to close
     * @param exitPrice Exit price (8 decimals)
     * @return pnl Profit/loss in USDC (6 decimals, can be negative)
     */
    function closePosition(
        uint256 positionId,
        uint256 exitPrice
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant returns (int256 pnl) {
        Position storage position = positions[positionId];
        require(position.id != 0, "PositionManager: Position not found");
        require(position.status == PositionStatus.OPEN, "PositionManager: Position not open");
        require(exitPrice > 0, "PositionManager: Invalid exit price");
        
        pnl = calculatePnL(positionId, exitPrice);
        position.status = PositionStatus.CLOSED;
        
        emit PositionClosed(positionId, exitPrice, pnl);
    }
    
    /**
     * @notice Liquidate a position
     * @param positionId Position ID to liquidate
     * @param liquidationPrice Price at liquidation (8 decimals)
     */
    function liquidatePosition(
        uint256 positionId,
        uint256 liquidationPrice
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        Position storage position = positions[positionId];
        require(position.id != 0, "PositionManager: Position not found");
        require(position.status == PositionStatus.OPEN, "PositionManager: Position not open");
        
        position.status = PositionStatus.LIQUIDATED;
        
        emit PositionLiquidated(positionId, liquidationPrice, msg.sender);
    }
    
    /**
     * @notice Calculate PnL for a position
     * @param positionId Position ID
     * @param currentPrice Current price (8 decimals)
     * @return pnl Profit/loss in USDC (6 decimals, can be negative)
     */
    function calculatePnL(
        uint256 positionId,
        uint256 currentPrice
    ) public view returns (int256 pnl) {
        Position memory position = positions[positionId];
        require(position.id != 0, "PositionManager: Position not found");
        require(currentPrice > 0, "PositionManager: Invalid price");
        
        int256 priceDiff;
        
        if (position.isLong) {
            // Long: profit when price goes up
            priceDiff = int256(currentPrice) - int256(position.entryPrice);
        } else {
            // Short: profit when price goes down
            priceDiff = int256(position.entryPrice) - int256(currentPrice);
        }
        
        // PnL = (priceDiff / entryPrice) * size
        // All amounts in USDC (6 decimals)
        // Prices in 8 decimals, so we need to adjust
        pnl = (priceDiff * int256(position.size)) / int256(position.entryPrice);
    }
    
    /**
     * @notice Get position details
     * @param positionId Position ID
     * @return position Position struct
     */
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }
    
    /**
     * @notice Get all position IDs for a user
     * @param user User address
     * @return positionIds Array of position IDs
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }
    
    /**
     * @notice Get all open positions for a user
     * @param user User address
     * @return openPositions Array of open positions
     */
    function getUserOpenPositions(address user) external view returns (Position[] memory) {
        uint256[] memory userPositionIds = userPositions[user];
        
        // Count open positions
        uint256 openCount = 0;
        for (uint256 i = 0; i < userPositionIds.length; i++) {
            if (positions[userPositionIds[i]].status == PositionStatus.OPEN) {
                openCount++;
            }
        }
        
        // Build array of open positions
        Position[] memory openPositions = new Position[](openCount);
        uint256 index = 0;
        for (uint256 i = 0; i < userPositionIds.length; i++) {
            if (positions[userPositionIds[i]].status == PositionStatus.OPEN) {
                openPositions[index] = positions[userPositionIds[i]];
                index++;
            }
        }
        
        return openPositions;
    }
    
    /**
     * @notice Check if position exists
     * @param positionId Position ID
     * @return exists Whether position exists
     */
    function positionExists(uint256 positionId) external view returns (bool) {
        return positions[positionId].id != 0;
    }
    
    /**
     * @notice Get position status
     * @param positionId Position ID
     * @return status Position status
     */
    function getPositionStatus(uint256 positionId) external view returns (PositionStatus) {
        require(positions[positionId].id != 0, "PositionManager: Position not found");
        return positions[positionId].status;
    }
}

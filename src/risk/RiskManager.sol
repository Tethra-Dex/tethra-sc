// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RiskManager
 * @notice Manages risk parameters for trading (leverage, position size, liquidation thresholds)
 * @dev Validates positions before they are opened
 */
contract RiskManager is Ownable {
    
    struct AssetConfig {
        bool enabled;                    // Whether trading is enabled for this asset
        uint256 maxLeverage;            // Maximum leverage allowed (e.g., 100 for 100x)
        uint256 maxPositionSize;        // Maximum position size in USDC (6 decimals)
        uint256 maxOpenInterest;        // Maximum total open interest (long + short)
        uint256 liquidationThresholdBps; // Liquidation threshold in basis points (8000 = 80%)
    }
    
    // Asset symbol => Configuration
    mapping(string => AssetConfig) public assetConfigs;
    
    // Asset symbol => Current open interest
    mapping(string => uint256) public currentOpenInterest;
    
    // Events
    event AssetConfigured(
        string indexed symbol,
        uint256 maxLeverage,
        uint256 maxPositionSize,
        uint256 maxOpenInterest,
        uint256 liquidationThresholdBps
    );
    
    event OpenInterestUpdated(string indexed symbol, uint256 newOpenInterest);
    
    constructor() Ownable(msg.sender) {}
    
    /**
     * @notice Configure risk parameters for an asset
     * @param symbol Asset symbol (e.g., "BTC", "ETH")
     * @param enabled Whether trading is enabled
     * @param maxLeverage Maximum leverage (e.g., 100 for 100x)
     * @param maxPositionSize Maximum position size in USDC
     * @param maxOpenInterest Maximum total open interest
     * @param liquidationThresholdBps Liquidation threshold (8000 = 80%)
     */
    function setAssetConfig(
        string calldata symbol,
        bool enabled,
        uint256 maxLeverage,
        uint256 maxPositionSize,
        uint256 maxOpenInterest,
        uint256 liquidationThresholdBps
    ) external onlyOwner {
        require(maxLeverage > 0, "RiskManager: Invalid leverage");
        require(maxPositionSize > 0, "RiskManager: Invalid position size");
        require(liquidationThresholdBps > 0 && liquidationThresholdBps < 10000, "RiskManager: Invalid threshold");
        
        assetConfigs[symbol] = AssetConfig({
            enabled: enabled,
            maxLeverage: maxLeverage,
            maxPositionSize: maxPositionSize,
            maxOpenInterest: maxOpenInterest,
            liquidationThresholdBps: liquidationThresholdBps
        });
        
        emit AssetConfigured(
            symbol,
            maxLeverage,
            maxPositionSize,
            maxOpenInterest,
            liquidationThresholdBps
        );
    }
    
    /**
     * @notice Validate a position before opening
     * @param symbol Asset symbol
     * @param collateral Collateral amount in USDC
     * @param leverage Leverage multiplier
     * @param size Position size (collateral * leverage)
     */
    function validatePosition(
        string calldata symbol,
        uint256 collateral,
        uint256 leverage,
        uint256 size
    ) external view {
        AssetConfig memory config = assetConfigs[symbol];
        
        require(config.enabled, "RiskManager: Asset not enabled");
        require(leverage > 0 && leverage <= config.maxLeverage, "RiskManager: Invalid leverage");
        require(size <= config.maxPositionSize, "RiskManager: Position too large");
        require(
            currentOpenInterest[symbol] + size <= config.maxOpenInterest,
            "RiskManager: Max open interest exceeded"
        );
        require(collateral > 0, "RiskManager: Invalid collateral");
        require(size == collateral * leverage, "RiskManager: Size mismatch");
    }
    
    /**
     * @notice Increase open interest when position is opened
     * @param symbol Asset symbol
     * @param size Position size to add
     */
    function increaseOpenInterest(string calldata symbol, uint256 size) external onlyOwner {
        currentOpenInterest[symbol] += size;
        emit OpenInterestUpdated(symbol, currentOpenInterest[symbol]);
    }
    
    /**
     * @notice Decrease open interest when position is closed
     * @param symbol Asset symbol
     * @param size Position size to remove
     */
    function decreaseOpenInterest(string calldata symbol, uint256 size) external onlyOwner {
        require(currentOpenInterest[symbol] >= size, "RiskManager: Underflow");
        currentOpenInterest[symbol] -= size;
        emit OpenInterestUpdated(symbol, currentOpenInterest[symbol]);
    }
    
    /**
     * @notice Calculate liquidation price for a position
     * @param isLong Whether position is long
     * @param entryPrice Entry price (8 decimals)
     * @param collateral Collateral amount
     * @param size Position size
     * @param symbol Asset symbol (for liquidation threshold)
     * @return Liquidation price (8 decimals)
     */
    function calculateLiquidationPrice(
        bool isLong,
        uint256 entryPrice,
        uint256 collateral,
        uint256 size,
        string calldata symbol
    ) external view returns (uint256) {
        AssetConfig memory config = assetConfigs[symbol];
        require(config.enabled, "RiskManager: Asset not enabled");
        
        // Calculate how much loss triggers liquidation
        uint256 maxLoss = (collateral * config.liquidationThresholdBps) / 10000;
        
        if (isLong) {
            // Long liquidation: price drops
            // liquidationPrice = entryPrice - (maxLoss * entryPrice / size)
            uint256 priceDrop = (maxLoss * entryPrice) / size;
            require(priceDrop < entryPrice, "RiskManager: Invalid liquidation price");
            return entryPrice - priceDrop;
        } else {
            // Short liquidation: price rises
            // liquidationPrice = entryPrice + (maxLoss * entryPrice / size)
            uint256 priceRise = (maxLoss * entryPrice) / size;
            return entryPrice + priceRise;
        }
    }
    
    /**
     * @notice Check if position should be liquidated
     * @param isLong Whether position is long
     * @param entryPrice Entry price
     * @param currentPrice Current price
     * @param collateral Collateral amount
     * @param size Position size
     * @param symbol Asset symbol
     * @return shouldLiquidate Whether position should be liquidated
     */
    function checkLiquidation(
        bool isLong,
        uint256 entryPrice,
        uint256 currentPrice,
        uint256 collateral,
        uint256 size,
        string calldata symbol
    ) external view returns (bool shouldLiquidate) {
        uint256 liquidationPrice = this.calculateLiquidationPrice(
            isLong,
            entryPrice,
            collateral,
            size,
            symbol
        );
        
        if (isLong) {
            // Long: liquidate if current price <= liquidation price
            return currentPrice <= liquidationPrice;
        } else {
            // Short: liquidate if current price >= liquidation price
            return currentPrice >= liquidationPrice;
        }
    }
    
    /**
     * @notice Get asset configuration
     * @param symbol Asset symbol
     * @return config Asset configuration
     */
    function getAssetConfig(string calldata symbol) external view returns (AssetConfig memory) {
        return assetConfigs[symbol];
    }
    
    /**
     * @notice Get current open interest for an asset
     * @param symbol Asset symbol
     * @return Open interest
     */
    function getOpenInterest(string calldata symbol) external view returns (uint256) {
        return currentOpenInterest[symbol];
    }
}

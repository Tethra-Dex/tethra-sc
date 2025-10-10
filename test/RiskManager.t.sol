// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/risk/RiskManager.sol";

contract RiskManagerTest is Test {
    RiskManager public riskManager;
    
    address public admin = address(this);
    address public trader = address(0x1);
    
    function setUp() public {
        riskManager = new RiskManager();
        
        // Setup BTC: 100x leverage
        riskManager.setAssetConfig(
            "BTC",
            true,              // enabled
            100,               // maxLeverage
            100_000 * 10**6,   // maxPositionSize
            1_000_000 * 10**6, // maxOpenInterest
            8000               // liquidationThreshold 80%
        );
        
        // Setup ETH: 100x leverage
        riskManager.setAssetConfig(
            "ETH",
            true,
            100,
            100_000 * 10**6,
            1_000_000 * 10**6,
            8000
        );
        
        // Setup SOL: 20x leverage (altcoin)
        riskManager.setAssetConfig(
            "SOL",
            true,
            20,
            50_000 * 10**6,
            500_000 * 10**6,
            8000
        );
    }
    
    // ====================
    // DEPLOYMENT TESTS
    // ====================
    
    function testDeployment() public {
        assertTrue(address(riskManager) != address(0));
    }
    
    // ====================
    // ASSET CONFIG TESTS
    // ====================
    
    function testSetAssetConfig() public {
        riskManager.setAssetConfig(
            "AVAX",
            true,
            20,
            50_000 * 10**6,
            500_000 * 10**6,
            8000
        );
        
        (bool enabled, uint256 maxLeverage,,,) = riskManager.assetConfigs("AVAX");
        assertTrue(enabled);
        assertEq(maxLeverage, 20);
    }
    
    function testSetAssetConfigUnauthorized() public {
        vm.prank(trader);
        vm.expectRevert();
        riskManager.setAssetConfig("AVAX", true, 20, 50_000 * 10**6, 500_000 * 10**6, 8000);
    }
    
    function testInvalidLeverage() public {
        vm.expectRevert("RiskManager: Invalid leverage");
        riskManager.setAssetConfig("TEST", true, 0, 100_000 * 10**6, 1_000_000 * 10**6, 8000);
    }
    
    function testInvalidPositionSize() public {
        vm.expectRevert("RiskManager: Invalid position size");
        riskManager.setAssetConfig("TEST", true, 10, 0, 1_000_000 * 10**6, 8000);
    }
    
    function testInvalidThreshold() public {
        vm.expectRevert("RiskManager: Invalid threshold");
        riskManager.setAssetConfig("TEST", true, 10, 100_000 * 10**6, 1_000_000 * 10**6, 0);
        
        vm.expectRevert("RiskManager: Invalid threshold");
        riskManager.setAssetConfig("TEST", true, 10, 100_000 * 10**6, 1_000_000 * 10**6, 10000);
    }
    
    // ====================
    // VALIDATE POSITION TESTS
    // ====================
    
    function testValidatePosition_Success() public view {
        // Should not revert
        riskManager.validatePosition(
            "BTC",
            1000 * 10**6,  // 1000 USDC collateral
            10,            // 10x leverage
            10000 * 10**6  // 10k USDC size
        );
    }
    
    function testValidatePosition_AssetNotEnabled() public {
        vm.expectRevert("RiskManager: Asset not enabled");
        riskManager.validatePosition("UNKNOWN", 1000 * 10**6, 10, 10000 * 10**6);
    }
    
    function testValidatePosition_LeverageTooHigh() public {
        vm.expectRevert("RiskManager: Invalid leverage");
        riskManager.validatePosition("BTC", 1000 * 10**6, 101, 101000 * 10**6);
    }
    
    function testValidatePosition_PositionTooLarge() public {
        vm.expectRevert("RiskManager: Position too large");
        riskManager.validatePosition("BTC", 200_000 * 10**6, 10, 2_000_000 * 10**6);
    }
    
    function testValidatePosition_SizeMismatch() public {
        vm.expectRevert("RiskManager: Size mismatch");
        riskManager.validatePosition("BTC", 1000 * 10**6, 10, 9000 * 10**6); // Should be 10k
    }
    
    // ====================
    // OPEN INTEREST TESTS
    // ====================
    
    function testIncreaseOpenInterest() public {
        riskManager.increaseOpenInterest("BTC", 50_000 * 10**6);
        assertEq(riskManager.currentOpenInterest("BTC"), 50_000 * 10**6);
    }
    
    function testDecreaseOpenInterest() public {
        riskManager.increaseOpenInterest("BTC", 50_000 * 10**6);
        riskManager.decreaseOpenInterest("BTC", 20_000 * 10**6);
        assertEq(riskManager.currentOpenInterest("BTC"), 30_000 * 10**6);
    }
    
    function testDecreaseOpenInterest_Underflow() public {
        vm.expectRevert("RiskManager: Underflow");
        riskManager.decreaseOpenInterest("BTC", 1000 * 10**6);
    }
    
    function testValidatePosition_MaxOpenInterestExceeded() public {
        // Fill up to max
        riskManager.increaseOpenInterest("BTC", 1_000_000 * 10**6);
        
        vm.expectRevert("RiskManager: Max open interest exceeded");
        riskManager.validatePosition("BTC", 1000 * 10**6, 10, 10000 * 10**6);
    }
    
    // ====================
    // LIQUIDATION TESTS
    // ====================
    
    function testCalculateLiquidationPrice_Long() public view {
        // Long position: BTC entry at 50000
        // Collateral: 1000 USDC, Size: 10000 USDC
        // 80% threshold means 800 USDC max loss
        // liquidationPrice = 50000 - (800 * 50000 / 10000) = 46000
        
        uint256 liqPrice = riskManager.calculateLiquidationPrice(
            true,              // isLong
            50000 * 10**8,     // entryPrice
            1000 * 10**6,      // collateral
            10000 * 10**6,     // size
            "BTC"
        );
        
        assertEq(liqPrice, 46000 * 10**8);
    }
    
    function testCalculateLiquidationPrice_Short() public view {
        // Short position: entry at 50000
        // liquidationPrice = 50000 + (800 * 50000 / 10000) = 54000
        
        uint256 liqPrice = riskManager.calculateLiquidationPrice(
            false,             // isShort
            50000 * 10**8,
            1000 * 10**6,
            10000 * 10**6,
            "BTC"
        );
        
        assertEq(liqPrice, 54000 * 10**8);
    }
    
    function testCheckLiquidation_Long_ShouldLiquidate() public view {
        // Long position at 50000, current 45000 (below liq price of 46000)
        bool shouldLiquidate = riskManager.checkLiquidation(
            true,
            50000 * 10**8,
            45000 * 10**8,
            1000 * 10**6,
            10000 * 10**6,
            "BTC"
        );
        
        assertTrue(shouldLiquidate);
    }
    
    function testCheckLiquidation_Long_ShouldNotLiquidate() public view {
        // Long position at 50000, current 47000 (above liq price)
        bool shouldLiquidate = riskManager.checkLiquidation(
            true,
            50000 * 10**8,
            47000 * 10**8,
            1000 * 10**6,
            10000 * 10**6,
            "BTC"
        );
        
        assertFalse(shouldLiquidate);
    }
    
    function testCheckLiquidation_Short_ShouldLiquidate() public view {
        // Short position at 50000, current 55000 (above liq price of 54000)
        bool shouldLiquidate = riskManager.checkLiquidation(
            false,
            50000 * 10**8,
            55000 * 10**8,
            1000 * 10**6,
            10000 * 10**6,
            "BTC"
        );
        
        assertTrue(shouldLiquidate);
    }
    
    function testCheckLiquidation_Short_ShouldNotLiquidate() public view {
        // Short position at 50000, current 53000 (below liq price)
        bool shouldLiquidate = riskManager.checkLiquidation(
            false,
            50000 * 10**8,
            53000 * 10**8,
            1000 * 10**6,
            10000 * 10**6,
            "BTC"
        );
        
        assertFalse(shouldLiquidate);
    }
    
    // ====================
    // MULTIPLE ASSETS TESTS
    // ====================
    
    function testMultipleAssets() public {
        // Add more assets
        riskManager.setAssetConfig("AVAX", true, 20, 50_000 * 10**6, 500_000 * 10**6, 8000);
        riskManager.setAssetConfig("MATIC", true, 20, 50_000 * 10**6, 500_000 * 10**6, 8000);
        
        // Verify they're configured
        (bool enabled1,,,, ) = riskManager.assetConfigs("AVAX");
        (bool enabled2,,,, ) = riskManager.assetConfigs("MATIC");
        
        assertTrue(enabled1);
        assertTrue(enabled2);
    }
    
    function testDisableAsset() public {
        riskManager.setAssetConfig("BTC", false, 100, 100_000 * 10**6, 1_000_000 * 10**6, 8000);
        
        (bool enabled,,,,) = riskManager.assetConfigs("BTC");
        assertFalse(enabled);
        
        vm.expectRevert("RiskManager: Asset not enabled");
        riskManager.validatePosition("BTC", 1000 * 10**6, 10, 10000 * 10**6);
    }
    
    // ====================
    // FUZZ TESTS
    // ====================
    
    function testFuzz_ValidatePosition(uint256 collateral, uint8 leverage) public view {
        collateral = bound(collateral, 10 * 10**6, 10_000 * 10**6);
        leverage = uint8(bound(leverage, 1, 100));
        
        uint256 size = collateral * leverage;
        if (size <= 100_000 * 10**6) {
            // Should not revert
            riskManager.validatePosition("BTC", collateral, leverage, size);
        }
    }
    
    function testFuzz_LiquidationPrice(uint256 entryPrice, uint256 collateral) public view {
        entryPrice = bound(entryPrice, 1000 * 10**8, 100_000 * 10**8);
        collateral = bound(collateral, 100 * 10**6, 10_000 * 10**6);
        
        uint256 size = collateral * 10; // 10x leverage
        
        uint256 liqPriceLong = riskManager.calculateLiquidationPrice(
            true,
            entryPrice,
            collateral,
            size,
            "BTC"
        );
        
        uint256 liqPriceShort = riskManager.calculateLiquidationPrice(
            false,
            entryPrice,
            collateral,
            size,
            "BTC"
        );
        
        // Long liq price should be below entry
        assertLt(liqPriceLong, entryPrice);
        
        // Short liq price should be above entry
        assertGt(liqPriceShort, entryPrice);
    }
}

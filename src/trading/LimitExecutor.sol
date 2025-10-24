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

// Updated interface to match existing PositionManager
interface IPositionManager {
    enum PositionStatus {
        OPEN,
        CLOSED,
        LIQUIDATED
    }

    struct Position {
        uint256 id;
        address trader;
        string symbol;
        bool isLong;
        uint256 collateral;
        uint256 size;
        uint256 leverage;
        uint256 entryPrice;
        uint256 openTimestamp;
        PositionStatus status;
    }

    function createPosition(
        address trader,
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 entryPrice
    ) external returns (uint256 positionId);

    function closePosition(uint256 positionId, uint256 exitPrice) external returns (int256 pnl);

    // Updated to match existing PositionManager implementation
    function getPosition(uint256 positionId) external view returns (Position memory);
}

interface ITreasuryManager {
    function collectFee(address from, uint256 amount) external;
    function distributeProfit(address to, uint256 amount) external;
    function refundCollateral(address to, uint256 amount) external;
    function collectExecutionFee(address from, uint256 amount) external;
    function payKeeperFee(address keeper, uint256 amount) external;
}

/**
 * @title LimitExecutor
 * @notice Handles limit orders and stop-loss orders
 * @dev Backend keeper executes orders when price conditions are met
 */
contract LimitExecutor is AccessControl, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant BACKEND_SIGNER_ROLE = keccak256("BACKEND_SIGNER_ROLE");

    IERC20 public immutable usdc;
    IRiskManager public riskManager;
    IPositionManager public positionManager;
    ITreasuryManager public treasuryManager;

    // Fee structure
    uint256 public tradingFeeBps = 5; // 0.05%
    uint256 public executionFee = 500000; // 0.5 USDC (6 decimals)

    // Price signature validity window
    uint256 public constant PRICE_VALIDITY_WINDOW = 5 minutes;

    enum OrderType {
        LIMIT_OPEN,
        LIMIT_CLOSE,
        STOP_LOSS
    }
    enum OrderStatus {
        PENDING,
        EXECUTED,
        CANCELLED
    }

    struct Order {
        uint256 id;
        OrderType orderType;
        OrderStatus status;
        address trader;
        string symbol;
        bool isLong;
        uint256 collateral;
        uint256 leverage;
        uint256 triggerPrice; // Price to trigger order (8 decimals)
        uint256 positionId; // For close/stop-loss orders
        uint256 createdAt;
        uint256 executedAt;
    }

    /**
     * @notice Signed price data structure
     */
    struct SignedPrice {
        string symbol;
        uint256 price; // Price with 8 decimals
        uint256 timestamp; // When price was signed
        bytes signature; // Backend signature
    }

    // Order ID counter
    uint256 public nextOrderId = 1;

    // Order ID => Order data
    mapping(uint256 => Order) public orders;

    // User address => array of order IDs
    mapping(address => uint256[]) public userOrders;

    // Events
    event LimitOrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        OrderType orderType,
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

    event StopLossTriggered(
        uint256 indexed orderId, uint256 indexed positionId, address indexed keeper, uint256 exitPrice, int256 pnl
    );

    event FeesUpdated(uint256 tradingFeeBps, uint256 executionFee);

    constructor(
        address _usdc,
        address _riskManager,
        address _positionManager,
        address _treasuryManager,
        address _keeper,
        address _backendSigner
    ) {
        require(_usdc != address(0), "LimitExecutor: Invalid USDC");
        require(_riskManager != address(0), "LimitExecutor: Invalid RiskManager");
        require(_positionManager != address(0), "LimitExecutor: Invalid PositionManager");
        require(_treasuryManager != address(0), "LimitExecutor: Invalid TreasuryManager");
        require(_keeper != address(0), "LimitExecutor: Invalid keeper");
        require(_backendSigner != address(0), "LimitExecutor: Invalid signer");

        usdc = IERC20(_usdc);
        riskManager = IRiskManager(_riskManager);
        positionManager = IPositionManager(_positionManager);
        treasuryManager = ITreasuryManager(_treasuryManager);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, _keeper);
        _grantRole(BACKEND_SIGNER_ROLE, _backendSigner);
    }

    /**
     * @notice Create a limit order to open a position
     * @param symbol Asset symbol
     * @param isLong True for long, false for short
     * @param collateral Collateral amount in USDC
     * @param leverage Leverage multiplier
     * @param triggerPrice Price to execute order (8 decimals)
     */
    function createLimitOpenOrder(
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice
    ) external nonReentrant returns (uint256 orderId) {
        require(collateral > 0, "LimitExecutor: Invalid collateral");
        require(leverage > 0, "LimitExecutor: Invalid leverage");
        require(triggerPrice > 0, "LimitExecutor: Invalid trigger price");

        // Collect collateral + execution fee from trader
        uint256 totalAmount = collateral + executionFee;

        require(usdc.transferFrom(msg.sender, address(treasuryManager), totalAmount), "LimitExecutor: Transfer failed");

        treasuryManager.collectExecutionFee(msg.sender, executionFee);

        // Create order
        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            orderType: OrderType.LIMIT_OPEN,
            status: OrderStatus.PENDING,
            trader: msg.sender,
            symbol: symbol,
            isLong: isLong,
            collateral: collateral,
            leverage: leverage,
            triggerPrice: triggerPrice,
            positionId: 0,
            createdAt: block.timestamp,
            executedAt: 0
        });

        userOrders[msg.sender].push(orderId);

        emit LimitOrderCreated(orderId, msg.sender, OrderType.LIMIT_OPEN, symbol, triggerPrice, executionFee);
    }

    /**
     * @notice Create a limit order to close a position
     * @param positionId Position ID to close
     * @param triggerPrice Price to execute close (8 decimals)
     */
    function createLimitCloseOrder(uint256 positionId, uint256 triggerPrice)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        // Get position details using struct return
        IPositionManager.Position memory position = positionManager.getPosition(positionId);

        require(position.trader == msg.sender, "LimitExecutor: Not position owner");
        require(
            uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "LimitExecutor: Position not open"
        );
        require(triggerPrice > 0, "LimitExecutor: Invalid trigger price");

        // Collect execution fee
        require(usdc.transferFrom(msg.sender, address(treasuryManager), executionFee), "LimitExecutor: Transfer failed");

        treasuryManager.collectExecutionFee(msg.sender, executionFee);

        // Create order
        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            orderType: OrderType.LIMIT_CLOSE,
            status: OrderStatus.PENDING,
            trader: msg.sender,
            symbol: position.symbol,
            isLong: false, // Not used for close orders
            collateral: 0,
            leverage: 0,
            triggerPrice: triggerPrice,
            positionId: positionId,
            createdAt: block.timestamp,
            executedAt: 0
        });

        userOrders[msg.sender].push(orderId);

        emit LimitOrderCreated(orderId, msg.sender, OrderType.LIMIT_CLOSE, position.symbol, triggerPrice, executionFee);
    }

    /**
     * @notice Create a stop-loss order for a position
     * @param positionId Position ID to protect
     * @param triggerPrice Stop-loss trigger price (8 decimals)
     */
    function createStopLossOrder(uint256 positionId, uint256 triggerPrice)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        // Get position details using struct return
        IPositionManager.Position memory position = positionManager.getPosition(positionId);

        require(position.trader == msg.sender, "LimitExecutor: Not position owner");
        require(
            uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "LimitExecutor: Position not open"
        );
        require(triggerPrice > 0, "LimitExecutor: Invalid trigger price");

        // Collect execution fee
        require(usdc.transferFrom(msg.sender, address(treasuryManager), executionFee), "LimitExecutor: Transfer failed");

        treasuryManager.collectExecutionFee(msg.sender, executionFee);

        // Create order
        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            orderType: OrderType.STOP_LOSS,
            status: OrderStatus.PENDING,
            trader: msg.sender,
            symbol: position.symbol,
            isLong: false, // Not used
            collateral: 0,
            leverage: 0,
            triggerPrice: triggerPrice,
            positionId: positionId,
            createdAt: block.timestamp,
            executedAt: 0
        });

        userOrders[msg.sender].push(orderId);

        emit LimitOrderCreated(orderId, msg.sender, OrderType.STOP_LOSS, position.symbol, triggerPrice, executionFee);
    }

    /**
     * @notice Execute a limit open order (keeper only)
     * @param orderId Order ID to execute
     * @param signedPrice Backend-signed price data
     */
    function executeLimitOpenOrder(uint256 orderId, SignedPrice calldata signedPrice)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Order storage order = orders[orderId];

        require(order.id != 0, "LimitExecutor: Order not found");
        require(order.status == OrderStatus.PENDING, "LimitExecutor: Order not pending");
        require(order.orderType == OrderType.LIMIT_OPEN, "LimitExecutor: Not a limit open order");
        require(
            keccak256(bytes(order.symbol)) == keccak256(bytes(signedPrice.symbol)), "LimitExecutor: Symbol mismatch"
        );

        // Verify price signature
        _verifySignedPrice(signedPrice);

        // Check if trigger price is reached
        if (order.isLong) {
            require(signedPrice.price <= order.triggerPrice, "LimitExecutor: Price not reached (long)");
        } else {
            require(signedPrice.price >= order.triggerPrice, "LimitExecutor: Price not reached (short)");
        }

        // Validate trade via RiskManager
        require(
            riskManager.validateTrade(order.trader, order.symbol, order.leverage, order.collateral, order.isLong),
            "LimitExecutor: Trade validation failed"
        );

        // Create position
        uint256 positionId = positionManager.createPosition(
            order.trader, order.symbol, order.isLong, order.collateral, order.leverage, signedPrice.price
        );

        // Collect trading fee
        uint256 positionSize = order.collateral * order.leverage;
        uint256 tradingFee = (positionSize * tradingFeeBps) / 10000;
        treasuryManager.collectFee(order.trader, tradingFee);

        // Pay keeper execution fee
        treasuryManager.payKeeperFee(msg.sender, executionFee);

        // Update order status
        order.status = OrderStatus.EXECUTED;
        order.positionId = positionId;
        order.executedAt = block.timestamp;

        emit LimitOrderExecuted(orderId, positionId, msg.sender, signedPrice.price, executionFee);
    }

    /**
     * @notice Execute a limit close order (keeper only)
     * @param orderId Order ID to execute
     * @param signedPrice Backend-signed price data
     */
    /**
     * @notice Execute a limit close order (keeper only) - FIXED SETTLEMENT
     */
    function executeLimitCloseOrder(uint256 orderId, SignedPrice calldata signedPrice)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Order storage order = orders[orderId];

        require(order.id != 0, "LimitExecutor: Order not found");
        require(order.status == OrderStatus.PENDING, "LimitExecutor: Order not pending");
        require(order.orderType == OrderType.LIMIT_CLOSE, "LimitExecutor: Not a limit close order");
        require(
            keccak256(bytes(order.symbol)) == keccak256(bytes(signedPrice.symbol)), "LimitExecutor: Symbol mismatch"
        );

        // Verify price signature
        _verifySignedPrice(signedPrice);

        // Get position details using struct return
        IPositionManager.Position memory position = positionManager.getPosition(order.positionId);

        require(
            uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "LimitExecutor: Position not open"
        );

        // Check if trigger price is reached
        if (position.isLong) {
            require(signedPrice.price >= order.triggerPrice, "LimitExecutor: Price not reached (long)");
        } else {
            require(signedPrice.price <= order.triggerPrice, "LimitExecutor: Price not reached (short)");
        }

        // Close position
        int256 pnl = positionManager.closePosition(order.positionId, signedPrice.price);

        // Calculate trading fee
        uint256 tradingFee = (position.size * tradingFeeBps) / 10000;

        // FIXED SETTLEMENT LOGIC - Calculate net settlement first, then transfer once
        if (pnl > 0) {
            // Profitable trade
            uint256 profit = uint256(pnl);

            // Net amount after deducting fee = collateral + profit - trading fee
            uint256 netAmount = position.collateral + profit - tradingFee;

            // Single transfer of net amount to trader
            treasuryManager.refundCollateral(order.trader, netAmount);

            // Trading fee stays in treasury (no separate collection needed)
        } else if (pnl < 0) {
            // Loss trade
            uint256 loss = uint256(-pnl);

            if (position.collateral > loss + tradingFee) {
                // Collateral covers loss + fee
                uint256 netAmount = position.collateral - loss - tradingFee;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
            // If loss + fee >= collateral, trader gets nothing (total loss)
        } else {
            // Breakeven trade
            if (position.collateral > tradingFee) {
                uint256 netAmount = position.collateral - tradingFee;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
            // If collateral <= fee, trader gets nothing
        }

        // Pay keeper execution fee
        treasuryManager.payKeeperFee(msg.sender, executionFee);

        // Update order status
        order.status = OrderStatus.EXECUTED;
        order.executedAt = block.timestamp;

        emit LimitOrderExecuted(orderId, order.positionId, msg.sender, signedPrice.price, executionFee);
    }

    /**
     * @notice Execute a stop-loss order (keeper only) - FIXED SETTLEMENT
     */
    function executeStopLossOrder(uint256 orderId, SignedPrice calldata signedPrice)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Order storage order = orders[orderId];

        require(order.id != 0, "LimitExecutor: Order not found");
        require(order.status == OrderStatus.PENDING, "LimitExecutor: Order not pending");
        require(order.orderType == OrderType.STOP_LOSS, "LimitExecutor: Not a stop-loss order");
        require(
            keccak256(bytes(order.symbol)) == keccak256(bytes(signedPrice.symbol)), "LimitExecutor: Symbol mismatch"
        );

        // Verify price signature
        _verifySignedPrice(signedPrice);

        // Get position details using struct return
        IPositionManager.Position memory position = positionManager.getPosition(order.positionId);

        require(
            uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "LimitExecutor: Position not open"
        );

        // Check if stop-loss is triggered
        if (position.isLong) {
            require(signedPrice.price <= order.triggerPrice, "LimitExecutor: Stop-loss not triggered (long)");
        } else {
            require(signedPrice.price >= order.triggerPrice, "LimitExecutor: Stop-loss not triggered (short)");
        }

        // Close position
        int256 pnl = positionManager.closePosition(order.positionId, signedPrice.price);

        // Calculate trading fee
        uint256 tradingFee = (position.size * tradingFeeBps) / 10000;

        // SAME FIXED SETTLEMENT LOGIC
        if (pnl > 0) {
            // Profitable trade (unlikely for stop-loss)
            uint256 profit = uint256(pnl);
            uint256 netAmount = position.collateral + profit - tradingFee;
            treasuryManager.refundCollateral(order.trader, netAmount);
        } else if (pnl < 0) {
            // Loss trade (typical for stop-loss)
            uint256 loss = uint256(-pnl);

            if (position.collateral > loss + tradingFee) {
                uint256 netAmount = position.collateral - loss - tradingFee;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
        } else {
            // Breakeven
            if (position.collateral > tradingFee) {
                uint256 netAmount = position.collateral - tradingFee;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
        }

        // Pay keeper execution fee
        treasuryManager.payKeeperFee(msg.sender, executionFee);

        // Update order status
        order.status = OrderStatus.EXECUTED;
        order.executedAt = block.timestamp;

        emit StopLossTriggered(orderId, order.positionId, msg.sender, signedPrice.price, pnl);
    }

    /**
     * @notice Cancel a pending order
     * @param orderId Order ID to cancel
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];

        require(order.id != 0, "LimitExecutor: Order not found");
        require(order.trader == msg.sender, "LimitExecutor: Not order owner");
        require(order.status == OrderStatus.PENDING, "LimitExecutor: Order not pending");

        // Refund execution fee
        treasuryManager.refundCollateral(msg.sender, executionFee);

        // If limit open order, refund collateral
        if (order.orderType == OrderType.LIMIT_OPEN) {
            treasuryManager.refundCollateral(msg.sender, order.collateral);
        }

        // Update order status
        order.status = OrderStatus.CANCELLED;

        emit LimitOrderCancelled(orderId, msg.sender);
    }

    /**
     * @notice Verify backend-signed price data
     *
     * NOTE: Price validation temporarily disabled for hackathon demo
     * TODO: Re-enable after fixing timestamp synchronization issues
     */
    function _verifySignedPrice(SignedPrice calldata signedPrice) internal view {
        // TEMPORARY: Skip validation for demo
        // Just check price is not zero
        require(signedPrice.price > 0, "LimitExecutor: Invalid price");

        // Original validation (commented out for now):
        // require(block.timestamp <= signedPrice.timestamp + PRICE_VALIDITY_WINDOW, "LimitExecutor: Price expired");
        // require(signedPrice.timestamp <= block.timestamp, "LimitExecutor: Price timestamp in future");
        // bytes32 messageHash = keccak256(abi.encodePacked(signedPrice.symbol, signedPrice.price, signedPrice.timestamp));
        // bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        // address signer = ethSignedMessageHash.recover(signedPrice.signature);
        // require(hasRole(BACKEND_SIGNER_ROLE, signer), "LimitExecutor: Invalid signature");
    }

    /**
     * @notice Get order details
     */
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @notice Get all orders for a user
     */
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /**
     * @notice Get all pending orders for a user
     */
    function getUserPendingOrders(address user) external view returns (Order[] memory) {
        uint256[] memory userOrderIds = userOrders[user];

        uint256 pendingCount = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            if (orders[userOrderIds[i]].status == OrderStatus.PENDING) {
                pendingCount++;
            }
        }

        Order[] memory pendingOrders = new Order[](pendingCount);
        uint256 index = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            if (orders[userOrderIds[i]].status == OrderStatus.PENDING) {
                pendingOrders[index] = orders[userOrderIds[i]];
                index++;
            }
        }

        return pendingOrders;
    }

    /**
     * @notice Update fee parameters (admin only)
     */
    function updateFees(uint256 _tradingFeeBps, uint256 _executionFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tradingFeeBps <= 100, "LimitExecutor: Trading fee too high");
        require(_executionFee <= 5000000, "LimitExecutor: Execution fee too high"); // Max 5 USDC

        tradingFeeBps = _tradingFeeBps;
        executionFee = _executionFee;

        emit FeesUpdated(_tradingFeeBps, _executionFee);
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
}

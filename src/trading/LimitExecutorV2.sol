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
 * @title LimitExecutorV2
 * @notice Gasless limit order system - User TIDAK perlu approve/transfer saat create order!
 * @dev Flow:
 *      1. User sign message (no on-chain tx)
 *      2. Keeper monitor price
 *      3. Keeper execute order on-chain (keeper bayar gas)
 *      4. Contract pull USDC dari user saat execute (bukan saat create)
 */
contract LimitExecutorV2 is AccessControl, ReentrancyGuard {
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

    // Price signature validity window
    uint256 public constant PRICE_VALIDITY_WINDOW = 5 minutes;

    // Order signature validity
    uint256 public constant ORDER_VALIDITY_PERIOD = 30 days;

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
        uint256 triggerPrice;
        uint256 positionId;
        uint256 createdAt;
        uint256 executedAt;
        uint256 expiresAt;
        uint256 nonce;
        uint256 maxExecutionFee;
        uint256 executionFeePaid;
    }

    struct SignedPrice {
        string symbol;
        uint256 price;
        uint256 timestamp;
        bytes signature;
    }

    // Order ID counter
    uint256 public nextOrderId = 1;

    // Order ID => Order data
    mapping(uint256 => Order) public orders;

    // User address => array of order IDs
    mapping(address => uint256[]) public userOrders;

    // User nonce for order signing (prevent replay attacks)
    mapping(address => uint256) public userOrderNonces;

    // Cancelled orders (to prevent execution after cancellation)
    mapping(uint256 => bool) public cancelledOrders;

    // Events
    event LimitOrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        OrderType orderType,
        string symbol,
        uint256 triggerPrice,
        uint256 nonce
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

    event TradingFeeUpdated(uint256 tradingFeeBps);

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
     * @notice Create limit open order - GASLESS VERSION (Keeper executes)
     * @dev User signs message off-chain, keeper creates order on-chain
     * @param trader User address
     * @param symbol Asset symbol
     * @param isLong Long or short
     * @param collateral Collateral amount
     * @param leverage Leverage
     * @param triggerPrice Trigger price
     * @param maxExecutionFee Maximum keeper fee user is willing to pay (in USDC, 6 decimals)
     * @param nonce User's current nonce
     * @param expiresAt Expiration timestamp
     * @param userSignature User's signature
     */
    function createLimitOpenOrder(
        address trader,
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        uint256 maxExecutionFee,
        uint256 nonce,
        uint256 expiresAt,
        bytes calldata userSignature
    ) external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 orderId) {
        require(collateral > 0, "Invalid collateral");
        require(leverage > 0, "Invalid leverage");
        require(triggerPrice > 0, "Invalid trigger price");
        require(maxExecutionFee > 0, "Invalid max execution fee");
        require(block.timestamp < expiresAt, "Order expired");
        require(expiresAt <= block.timestamp + ORDER_VALIDITY_PERIOD, "Expiry too far");
        require(nonce == userOrderNonces[trader], "Invalid nonce");

        // Verify user signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                trader,
                symbol,
                isLong,
                collateral,
                leverage,
                triggerPrice,
                maxExecutionFee,
                nonce,
                expiresAt,
                address(this)
            )
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(userSignature);
        require(signer == trader, "Invalid signature");

        // Increment nonce to prevent replay
        userOrderNonces[trader]++;

        // Create order (NO USDC TRANSFER YET!)
        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            orderType: OrderType.LIMIT_OPEN,
            status: OrderStatus.PENDING,
            trader: trader,
            symbol: symbol,
            isLong: isLong,
            collateral: collateral,
            leverage: leverage,
            triggerPrice: triggerPrice,
            positionId: 0,
            createdAt: block.timestamp,
            executedAt: 0,
            expiresAt: expiresAt,
            nonce: nonce,
            maxExecutionFee: maxExecutionFee,
            executionFeePaid: 0
        });

        userOrders[trader].push(orderId);

        emit LimitOrderCreated(orderId, trader, OrderType.LIMIT_OPEN, symbol, triggerPrice, nonce);
    }

    /**
     * @notice Execute limit open order - KEEPER BAYAR GAS, CONTRACT PULL USDC DARI USER
     * @param orderId Order ID
     * @param signedPrice Signed price from backend
     */
    function executeLimitOpenOrder(uint256 orderId, SignedPrice calldata signedPrice, uint256 executionFeePaid)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Order storage order = orders[orderId];

        require(order.id != 0, "Order not found");
        require(!cancelledOrders[orderId], "Order cancelled");
        require(order.status == OrderStatus.PENDING, "Order not pending");
        require(order.orderType == OrderType.LIMIT_OPEN, "Not limit open");
        require(block.timestamp < order.expiresAt, "Order expired");
        require(keccak256(bytes(order.symbol)) == keccak256(bytes(signedPrice.symbol)), "Symbol mismatch");
        require(executionFeePaid > 0, "Execution fee required");
        require(executionFeePaid <= order.maxExecutionFee, "Execution fee above max");

        // Verify price signature
        _verifySignedPrice(signedPrice);

        // Check trigger price
        if (order.isLong) {
            require(signedPrice.price <= order.triggerPrice, "Price not reached (long)");
        } else {
            require(signedPrice.price >= order.triggerPrice, "Price not reached (short)");
        }

        // Validate trade
        require(
            riskManager.validateTrade(order.trader, order.symbol, order.leverage, order.collateral, order.isLong),
            "Trade validation failed"
        );

        // Calculate total cost
        uint256 positionSize = order.collateral * order.leverage;
        uint256 tradingFee = (positionSize * tradingFeeBps) / 10000;
        uint256 totalCost = order.collateral + tradingFee + executionFeePaid;

        // NOW PULL USDC FROM USER (user must have approved contract beforehand)
        require(usdc.transferFrom(order.trader, address(treasuryManager), totalCost), "USDC transfer failed");

        // Create position
        uint256 positionId = positionManager.createPosition(
            order.trader, order.symbol, order.isLong, order.collateral, order.leverage, signedPrice.price
        );

        // Collect fees (already transferred above)
        treasuryManager.collectFee(order.trader, tradingFee);
        treasuryManager.collectExecutionFee(order.trader, executionFeePaid);

        // Pay keeper
        treasuryManager.payKeeperFee(msg.sender, executionFeePaid);

        // Update order
        order.status = OrderStatus.EXECUTED;
        order.positionId = positionId;
        order.executedAt = block.timestamp;
        order.executionFeePaid = executionFeePaid;

        emit LimitOrderExecuted(orderId, positionId, msg.sender, signedPrice.price, executionFeePaid);
    }

    /**
     * @notice Cancel pending order - USER ONLY
     * @param orderId Order ID to cancel
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];

        require(order.id != 0, "Order not found");
        require(order.trader == msg.sender, "Not order owner");
        require(order.status == OrderStatus.PENDING, "Order not pending");
        require(!cancelledOrders[orderId], "Already cancelled");

        // Mark as cancelled
        order.status = OrderStatus.CANCELLED;
        cancelledOrders[orderId] = true;

        emit LimitOrderCancelled(orderId, msg.sender);
    }

    /**
     * @notice Create limit close order (Take Profit) - GASLESS VERSION
     */
    function createLimitCloseOrder(
        address trader,
        uint256 positionId,
        uint256 triggerPrice,
        uint256 maxExecutionFee,
        uint256 nonce,
        uint256 expiresAt,
        bytes calldata userSignature
    ) external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 orderId) {
        require(triggerPrice > 0, "Invalid trigger price");
        require(block.timestamp < expiresAt, "Order expired");
        require(nonce == userOrderNonces[trader], "Invalid nonce");
        require(maxExecutionFee > 0, "Invalid max execution fee");

        // Get position
        IPositionManager.Position memory position = positionManager.getPosition(positionId);
        require(position.trader == trader, "Not position owner");
        require(uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "Position not open");

        // Verify signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(trader, positionId, triggerPrice, maxExecutionFee, nonce, expiresAt, address(this))
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(userSignature);
        require(signer == trader, "Invalid signature");

        userOrderNonces[trader]++;

        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            orderType: OrderType.LIMIT_CLOSE,
            status: OrderStatus.PENDING,
            trader: trader,
            symbol: position.symbol,
            isLong: false,
            collateral: 0,
            leverage: 0,
            triggerPrice: triggerPrice,
            positionId: positionId,
            createdAt: block.timestamp,
            executedAt: 0,
            expiresAt: expiresAt,
            nonce: nonce,
            maxExecutionFee: maxExecutionFee,
            executionFeePaid: 0
        });

        userOrders[trader].push(orderId);

        emit LimitOrderCreated(orderId, trader, OrderType.LIMIT_CLOSE, position.symbol, triggerPrice, nonce);
    }

    /**
     * @notice Execute limit close order
     */
    function executeLimitCloseOrder(uint256 orderId, SignedPrice calldata signedPrice, uint256 executionFeePaid)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Order storage order = orders[orderId];

        require(order.id != 0, "Order not found");
        require(!cancelledOrders[orderId], "Order cancelled");
        require(order.status == OrderStatus.PENDING, "Order not pending");
        require(order.orderType == OrderType.LIMIT_CLOSE, "Not limit close");
        require(block.timestamp < order.expiresAt, "Order expired");
        require(executionFeePaid > 0, "Execution fee required");
        require(executionFeePaid <= order.maxExecutionFee, "Execution fee above max");

        _verifySignedPrice(signedPrice);

        IPositionManager.Position memory position = positionManager.getPosition(order.positionId);
        require(uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "Position not open");

        // Check trigger
        if (position.isLong) {
            require(signedPrice.price >= order.triggerPrice, "Price not reached (long)");
        } else {
            require(signedPrice.price <= order.triggerPrice, "Price not reached (short)");
        }

        // Close position
        int256 pnl = positionManager.closePosition(order.positionId, signedPrice.price);

        // Settle
        uint256 tradingFee = (position.size * tradingFeeBps) / 10000;

        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            uint256 netAmount = position.collateral + profit - tradingFee - executionFeePaid;
            treasuryManager.refundCollateral(order.trader, netAmount);
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            if (position.collateral > loss + tradingFee + executionFeePaid) {
                uint256 netAmount = position.collateral - loss - tradingFee - executionFeePaid;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
        } else {
            if (position.collateral > tradingFee + executionFeePaid) {
                uint256 netAmount = position.collateral - tradingFee - executionFeePaid;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
        }

        // Pay keeper
        treasuryManager.payKeeperFee(msg.sender, executionFeePaid);

        order.status = OrderStatus.EXECUTED;
        order.executedAt = block.timestamp;
        order.executionFeePaid = executionFeePaid;

        emit LimitOrderExecuted(orderId, order.positionId, msg.sender, signedPrice.price, executionFeePaid);
    }

    /**
     * @notice Create stop loss order - GASLESS VERSION
     */
    function createStopLossOrder(
        address trader,
        uint256 positionId,
        uint256 triggerPrice,
        uint256 maxExecutionFee,
        uint256 nonce,
        uint256 expiresAt,
        bytes calldata userSignature
    ) external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 orderId) {
        require(triggerPrice > 0, "Invalid trigger price");
        require(block.timestamp < expiresAt, "Order expired");
        require(nonce == userOrderNonces[trader], "Invalid nonce");
        require(maxExecutionFee > 0, "Invalid max execution fee");

        IPositionManager.Position memory position = positionManager.getPosition(positionId);
        require(position.trader == trader, "Not position owner");
        require(uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "Position not open");

        // Verify signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                trader,
                positionId,
                triggerPrice,
                maxExecutionFee,
                nonce,
                expiresAt,
                address(this),
                "STOP_LOSS" // Distinguish from limit close
            )
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(userSignature);
        require(signer == trader, "Invalid signature");

        userOrderNonces[trader]++;

        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            orderType: OrderType.STOP_LOSS,
            status: OrderStatus.PENDING,
            trader: trader,
            symbol: position.symbol,
            isLong: false,
            collateral: 0,
            leverage: 0,
            triggerPrice: triggerPrice,
            positionId: positionId,
            createdAt: block.timestamp,
            executedAt: 0,
            expiresAt: expiresAt,
            nonce: nonce,
            maxExecutionFee: maxExecutionFee,
            executionFeePaid: 0
        });

        userOrders[trader].push(orderId);

        emit LimitOrderCreated(orderId, trader, OrderType.STOP_LOSS, position.symbol, triggerPrice, nonce);
    }

    /**
     * @notice Execute stop loss order
     */
    function executeStopLossOrder(uint256 orderId, SignedPrice calldata signedPrice, uint256 executionFeePaid)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Order storage order = orders[orderId];

        require(order.id != 0, "Order not found");
        require(!cancelledOrders[orderId], "Order cancelled");
        require(order.status == OrderStatus.PENDING, "Order not pending");
        require(order.orderType == OrderType.STOP_LOSS, "Not stop loss");
        require(block.timestamp < order.expiresAt, "Order expired");
        require(executionFeePaid > 0, "Execution fee required");
        require(executionFeePaid <= order.maxExecutionFee, "Execution fee above max");

        _verifySignedPrice(signedPrice);

        IPositionManager.Position memory position = positionManager.getPosition(order.positionId);
        require(uint8(position.status) == uint8(IPositionManager.PositionStatus.OPEN), "Position not open");

        // Check trigger
        if (position.isLong) {
            require(signedPrice.price <= order.triggerPrice, "Stop not triggered (long)");
        } else {
            require(signedPrice.price >= order.triggerPrice, "Stop not triggered (short)");
        }

        // Close position
        int256 pnl = positionManager.closePosition(order.positionId, signedPrice.price);

        // Settle (same as limit close)
        uint256 tradingFee = (position.size * tradingFeeBps) / 10000;

        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            uint256 netAmount = position.collateral + profit - tradingFee - executionFeePaid;
            treasuryManager.refundCollateral(order.trader, netAmount);
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            if (position.collateral > loss + tradingFee + executionFeePaid) {
                uint256 netAmount = position.collateral - loss - tradingFee - executionFeePaid;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
        } else {
            if (position.collateral > tradingFee + executionFeePaid) {
                uint256 netAmount = position.collateral - tradingFee - executionFeePaid;
                treasuryManager.refundCollateral(order.trader, netAmount);
            }
        }

        treasuryManager.payKeeperFee(msg.sender, executionFeePaid);

        order.status = OrderStatus.EXECUTED;
        order.executedAt = block.timestamp;
        order.executionFeePaid = executionFeePaid;

        emit StopLossTriggered(orderId, order.positionId, msg.sender, signedPrice.price, pnl);
    }

    function _verifySignedPrice(SignedPrice calldata signedPrice) internal view {
        require(block.timestamp <= signedPrice.timestamp + PRICE_VALIDITY_WINDOW, "Price expired");
        require(signedPrice.timestamp <= block.timestamp, "Price in future");

        bytes32 messageHash = keccak256(abi.encodePacked(signedPrice.symbol, signedPrice.price, signedPrice.timestamp));

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(signedPrice.signature);

        require(hasRole(BACKEND_SIGNER_ROLE, signer), "Invalid price signature");
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    function getUserPendingOrders(address user) external view returns (Order[] memory) {
        uint256[] memory userOrderIds = userOrders[user];

        uint256 pendingCount = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            uint256 orderId = userOrderIds[i];
            if (orders[orderId].status == OrderStatus.PENDING && !cancelledOrders[orderId]) {
                pendingCount++;
            }
        }

        Order[] memory pendingOrders = new Order[](pendingCount);
        uint256 index = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            uint256 orderId = userOrderIds[i];
            if (orders[orderId].status == OrderStatus.PENDING && !cancelledOrders[orderId]) {
                pendingOrders[index] = orders[orderId];
                index++;
            }
        }

        return pendingOrders;
    }

    function getUserCurrentNonce(address user) external view returns (uint256) {
        return userOrderNonces[user];
    }

    function updateTradingFee(uint256 _tradingFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tradingFeeBps <= 100, "Trading fee too high");

        tradingFeeBps = _tradingFeeBps;

        emit TradingFeeUpdated(_tradingFeeBps);
    }

    function updateContracts(address _riskManager, address _positionManager, address _treasuryManager)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_riskManager != address(0)) riskManager = IRiskManager(_riskManager);
        if (_positionManager != address(0)) positionManager = IPositionManager(_positionManager);
        if (_treasuryManager != address(0)) treasuryManager = ITreasuryManager(_treasuryManager);
    }
}

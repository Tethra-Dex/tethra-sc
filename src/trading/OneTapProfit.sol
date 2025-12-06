// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface ITreasuryManager {
    function collectFeeWithRelayerSplit(address from, address relayer, uint256 totalFeeAmount) external;
    function distributeProfit(address to, uint256 amount) external;
    function refundCollateral(address to, uint256 amount) external;
}

/**
 * @title OneTapProfit
 * @notice Binary option-style trading where users bet on price reaching specific grid targets
 * @dev Users click grid targets, pay USDC, win if price reaches target within time window
 */
contract OneTapProfit is AccessControl, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant BACKEND_SIGNER_ROLE = keccak256("BACKEND_SIGNER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    IERC20 public immutable usdc;
    ITreasuryManager public treasuryManager;

    // Constants
    uint256 public constant MIN_TIME_OFFSET = 10; // Minimum 10 seconds from current time
    uint256 public constant GRID_DURATION = 10; // Each grid = 10 seconds
    uint256 public constant BASE_MULTIPLIER = 110; // 1.1x base (110 = 1.10x in basis of 100)
    uint256 public constant TRADING_FEE_BPS = 5; // 0.05% trading fee
    uint256 public constant PRICE_DECIMALS = 8; // Pyth price has 8 decimals

    // Bet tracking
    uint256 public nextBetId;
    mapping(uint256 => Bet) public bets;
    mapping(address => uint256[]) public userBets;

    // Meta-transaction nonces for gasless transactions
    mapping(address => uint256) public metaNonces;

    enum BetStatus {
        ACTIVE, // Bet is active, waiting for target or expiry
        WON, // Target reached, user won
        LOST, // Expired without reaching target
        CANCELLED // Cancelled by admin

    }

    struct Bet {
        uint256 betId;
        address trader;
        string symbol; // e.g., "BTC", "ETH"
        uint256 betAmount; // USDC amount (6 decimals)
        uint256 targetPrice; // Target price (8 decimals)
        uint256 targetTime; // Target timestamp
        uint256 entryPrice; // Price when bet was placed (8 decimals)
        uint256 entryTime; // Timestamp when bet was placed
        uint256 multiplier; // Payout multiplier (basis 100, e.g., 110 = 1.1x)
        BetStatus status;
        uint256 settledAt; // When bet was settled
        uint256 settlePrice; // Price at settlement
    }

    // Events
    event BetPlaced(
        uint256 indexed betId,
        address indexed trader,
        string symbol,
        uint256 betAmount,
        uint256 targetPrice,
        uint256 targetTime,
        uint256 entryPrice,
        uint256 multiplier
    );

    event BetSettled(
        uint256 indexed betId,
        address indexed trader,
        BetStatus status,
        uint256 payout,
        uint256 fee,
        uint256 settlePrice
    );

    event MetaTransactionExecuted(address indexed userAddress, address indexed relayerAddress, uint256 nonce);
    event KeeperExecutionSuccess(address indexed keeper, address indexed trader, uint256 betId);

    constructor(address _usdc, address _treasuryManager, address _backendSigner, address _keeper, address _settler) {
        require(_usdc != address(0), "OneTapProfit: Invalid USDC");
        require(_treasuryManager != address(0), "OneTapProfit: Invalid TreasuryManager");
        require(_backendSigner != address(0), "OneTapProfit: Invalid signer");
        require(_keeper != address(0), "OneTapProfit: Invalid keeper");
        require(_settler != address(0), "OneTapProfit: Invalid settler");

        usdc = IERC20(_usdc);
        treasuryManager = ITreasuryManager(_treasuryManager);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BACKEND_SIGNER_ROLE, _backendSigner);
        _grantRole(KEEPER_ROLE, _keeper);
        _grantRole(SETTLER_ROLE, _settler);
    }

    /**
     * @notice Calculate multiplier based on distance and time
     * @param entryPrice Current price when bet is placed
     * @param targetPrice Target price user is betting on
     * @param entryTime Current time when bet is placed
     * @param targetTime Target time user is betting on
     * @return multiplier Payout multiplier (basis 100, e.g., 150 = 1.5x)
     */
    function calculateMultiplier(uint256 entryPrice, uint256 targetPrice, uint256 entryTime, uint256 targetTime)
        public
        pure
        returns (uint256)
    {
        // Calculate price distance percentage (in basis points)
        uint256 priceDistance;
        if (targetPrice > entryPrice) {
            priceDistance = ((targetPrice - entryPrice) * 10000) / entryPrice;
        } else {
            priceDistance = ((entryPrice - targetPrice) * 10000) / entryPrice;
        }

        // Calculate time distance in seconds
        uint256 timeDistance = targetTime > entryTime ? targetTime - entryTime : 0;

        // Combined distance factor: price (60%) + time (40%)
        // Each 1% price distance adds 0.02x (2 points)
        // Each 10 seconds adds 0.01x (1 point)
        uint256 priceComponent = (priceDistance * 60) / 10000; // 0.6% per 1% price distance
        uint256 timeComponent = (timeDistance * 40) / (10 * 100); // 0.4% per 10 seconds

        // Multiplier = BASE_MULTIPLIER + combined distance
        // Minimum 1.1x, scales up with distance
        uint256 multiplier = BASE_MULTIPLIER + priceComponent + timeComponent;

        // Cap maximum multiplier at 10x (1000 points)
        if (multiplier > 1000) {
            multiplier = 1000;
        }

        return multiplier;
    }

    /**
     * @notice Place a bet via meta-transaction (gasless)
     * @param trader The actual trader address (from AA wallet)
     * @param symbol Asset symbol (e.g., "BTC", "ETH")
     * @param betAmount USDC amount to bet (6 decimals)
     * @param targetPrice Target price user bets on (8 decimals)
     * @param targetTime Target time user bets on (Unix timestamp)
     * @param entryPrice Current price when bet is placed (8 decimals)
     * @param entryTime Current time when bet is placed (Unix timestamp)
     * @param userSignature Signature from trader approving this bet
     */
    function placeBetMeta(
        address trader,
        string calldata symbol,
        uint256 betAmount,
        uint256 targetPrice,
        uint256 targetTime,
        uint256 entryPrice,
        uint256 entryTime,
        bytes calldata userSignature
    ) external nonReentrant returns (uint256 betId) {
        // Verify user signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(trader, symbol, betAmount, targetPrice, targetTime, metaNonces[trader], address(this))
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(userSignature);

        require(signer == trader, "OneTapProfit: Invalid user signature");

        // Increment nonce to prevent replay
        metaNonces[trader]++;

        // Validate bet parameters
        require(betAmount > 0, "OneTapProfit: Invalid bet amount");
        require(targetPrice > 0, "OneTapProfit: Invalid target price");
        require(entryPrice > 0, "OneTapProfit: Invalid entry price");
        require(targetTime > entryTime, "OneTapProfit: Target time must be future");
        require(targetTime >= entryTime + MIN_TIME_OFFSET, "OneTapProfit: Target too close");

        // Calculate multiplier
        uint256 multiplier = calculateMultiplier(entryPrice, targetPrice, entryTime, targetTime);

        // Transfer USDC from trader to treasury
        require(usdc.transferFrom(trader, address(treasuryManager), betAmount), "OneTapProfit: Transfer failed");

        // Create bet
        betId = nextBetId++;
        bets[betId] = Bet({
            betId: betId,
            trader: trader,
            symbol: symbol,
            betAmount: betAmount,
            targetPrice: targetPrice,
            targetTime: targetTime,
            entryPrice: entryPrice,
            entryTime: entryTime,
            multiplier: multiplier,
            status: BetStatus.ACTIVE,
            settledAt: 0,
            settlePrice: 0
        });

        userBets[trader].push(betId);

        emit MetaTransactionExecuted(trader, msg.sender, metaNonces[trader] - 1);
        emit BetPlaced(betId, trader, symbol, betAmount, targetPrice, targetTime, entryPrice, multiplier);

        return betId;
    }

    /**
     * @notice Place a bet via keeper (fully gasless for user)
     * @dev Backend validates session key signature off-chain, keeper executes without signature verification
     * @param trader The actual trader address
     * @param symbol Asset symbol (e.g., "BTC", "ETH")
     * @param betAmount USDC amount to bet (6 decimals)
     * @param targetPrice Target price user bets on (8 decimals)
     * @param targetTime Target time user bets on (Unix timestamp)
     * @param entryPrice Current price when bet is placed (8 decimals)
     * @param entryTime Current time when bet is placed (Unix timestamp)
     */
    function placeBetByKeeper(
        address trader,
        string calldata symbol,
        uint256 betAmount,
        uint256 targetPrice,
        uint256 targetTime,
        uint256 entryPrice,
        uint256 entryTime
    ) external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 betId) {
        // Validate bet parameters
        require(betAmount > 0, "OneTapProfit: Invalid bet amount");
        require(targetPrice > 0, "OneTapProfit: Invalid target price");
        require(entryPrice > 0, "OneTapProfit: Invalid entry price");
        require(targetTime > entryTime, "OneTapProfit: Target time must be future");
        require(targetTime >= entryTime + MIN_TIME_OFFSET, "OneTapProfit: Target too close");

        // Calculate multiplier
        uint256 multiplier = calculateMultiplier(entryPrice, targetPrice, entryTime, targetTime);

        // Transfer USDC from trader to treasury (keeper pays gas, not trader)
        require(usdc.transferFrom(trader, address(treasuryManager), betAmount), "OneTapProfit: Transfer failed");

        // Create bet
        betId = nextBetId++;
        bets[betId] = Bet({
            betId: betId,
            trader: trader,
            symbol: symbol,
            betAmount: betAmount,
            targetPrice: targetPrice,
            targetTime: targetTime,
            entryPrice: entryPrice,
            entryTime: entryTime,
            multiplier: multiplier,
            status: BetStatus.ACTIVE,
            settledAt: 0,
            settlePrice: 0
        });

        userBets[trader].push(betId);

        emit KeeperExecutionSuccess(msg.sender, trader, betId);
        emit BetPlaced(betId, trader, symbol, betAmount, targetPrice, targetTime, entryPrice, multiplier);

        return betId;
    }

    /**
     * @notice Settle a bet (called by backend settler)
     * @param betId Bet ID to settle
     * @param currentPrice Current price at settlement (8 decimals)
     * @param currentTime Current time at settlement (Unix timestamp)
     * @param won Whether the bet won (target reached before/at target time)
     */
    function settleBet(uint256 betId, uint256 currentPrice, uint256 currentTime, bool won)
        external
        onlyRole(SETTLER_ROLE)
        nonReentrant
    {
        Bet storage bet = bets[betId];

        require(bet.status == BetStatus.ACTIVE, "OneTapProfit: Bet not active");
        require(currentPrice > 0, "OneTapProfit: Invalid current price");

        // Update bet status
        bet.status = won ? BetStatus.WON : BetStatus.LOST;
        bet.settledAt = currentTime;
        bet.settlePrice = currentPrice;

        uint256 payout = 0;
        uint256 fee = 0;

        if (won) {
            // Calculate payout: betAmount * multiplier
            // multiplier is in basis 100, so divide by 100
            payout = (bet.betAmount * bet.multiplier) / 100;

            // Calculate fee from payout (0.05%)
            fee = (payout * TRADING_FEE_BPS) / 100000;

            // Net payout after fee
            uint256 netPayout = payout - fee;

            // Distribute profit to trader (fee is kept in treasury)
            // Note: betAmount already in treasury, profit = payout - betAmount
            // Treasury pays out: netPayout, keeps: betAmount + fee - netPayout as revenue
            treasuryManager.distributeProfit(bet.trader, netPayout);
        } else {
            // Lost: bet amount stays in treasury as revenue
            // No fee collection needed - bet amount already transferred in placeBetMeta
            fee = 0; // No additional fee on loss
        }

        emit BetSettled(betId, bet.trader, bet.status, payout, fee, currentPrice);
    }

    /**
     * @notice Get bet details
     * @param betId Bet ID
     */
    function getBet(uint256 betId)
        external
        view
        returns (
            uint256 id,
            address trader,
            string memory symbol,
            uint256 betAmount,
            uint256 targetPrice,
            uint256 targetTime,
            uint256 entryPrice,
            uint256 entryTime,
            uint256 multiplier,
            BetStatus status,
            uint256 settledAt,
            uint256 settlePrice
        )
    {
        Bet memory bet = bets[betId];
        return (
            bet.betId,
            bet.trader,
            bet.symbol,
            bet.betAmount,
            bet.targetPrice,
            bet.targetTime,
            bet.entryPrice,
            bet.entryTime,
            bet.multiplier,
            bet.status,
            bet.settledAt,
            bet.settlePrice
        );
    }

    /**
     * @notice Get user's bet IDs
     * @param user User address
     */
    function getUserBets(address user) external view returns (uint256[] memory) {
        return userBets[user];
    }

    /**
     * @notice Get active bets count
     */
    function getActiveBetsCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < nextBetId; i++) {
            if (bets[i].status == BetStatus.ACTIVE) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Update treasury manager (admin only)
     */
    function updateTreasuryManager(address _treasuryManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasuryManager != address(0), "OneTapProfit: Invalid address");
        treasuryManager = ITreasuryManager(_treasuryManager);
    }

    /**
     * @notice Cancel a bet (admin only, for emergencies)
     * @param betId Bet ID to cancel
     */
    function cancelBet(uint256 betId) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Bet storage bet = bets[betId];

        require(bet.status == BetStatus.ACTIVE, "OneTapProfit: Bet not active");

        bet.status = BetStatus.CANCELLED;

        // Refund bet amount to trader
        treasuryManager.refundCollateral(bet.trader, bet.betAmount);

        emit BetSettled(betId, bet.trader, BetStatus.CANCELLED, 0, 0, 0);
    }
}

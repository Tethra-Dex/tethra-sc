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
}

interface ITreasuryManager {
    function collectFee(address from, uint256 amount) external;
}

/**
 * @title TapToTradeExecutor
 * @notice Dedicated contract for tap-to-trade with session key support
 * @dev Allows traders to authorize session keys for gasless, signature-less trading
 */
contract TapToTradeExecutor is AccessControl, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant BACKEND_SIGNER_ROLE = keccak256("BACKEND_SIGNER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC20 public immutable usdc;
    IRiskManager public riskManager;
    IPositionManager public positionManager;
    ITreasuryManager public treasuryManager;

    // Fee structure (in basis points, 1 bp = 0.01%)
    uint256 public tradingFeeBps = 5; // 0.05%

    // Price signature validity window (5 minutes)
    uint256 public constant PRICE_VALIDITY_WINDOW = 5 minutes;

    // Meta-transaction nonces for gasless transactions
    mapping(address => uint256) public metaNonces;

    // Session key management
    struct SessionKey {
        address keyAddress; // Session key address
        uint256 expiresAt; // Expiration timestamp
        bool isActive; // Active status
    }

    // Mapping: trader => session key address => SessionKey
    mapping(address => mapping(address => SessionKey)) public sessionKeys;

    // Session key validity window (max 2 hours)
    uint256 public constant MAX_SESSION_DURATION = 2 hours;

    // Events
    event SessionKeyAuthorized(address indexed trader, address indexed sessionKey, uint256 expiresAt);
    event SessionKeyRevoked(address indexed trader, address indexed sessionKey);

    event TapToTradeOrderExecuted(
        uint256 indexed positionId,
        address indexed trader,
        string symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        uint256 price,
        address indexed signer
    );

    event MetaTransactionExecuted(address indexed userAddress, address indexed relayerAddress, uint256 nonce);

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
        require(_usdc != address(0), "TapToTradeExecutor: Invalid USDC");
        require(_riskManager != address(0), "TapToTradeExecutor: Invalid RiskManager");
        require(_positionManager != address(0), "TapToTradeExecutor: Invalid PositionManager");
        require(_treasuryManager != address(0), "TapToTradeExecutor: Invalid TreasuryManager");
        require(_backendSigner != address(0), "TapToTradeExecutor: Invalid signer");

        usdc = IERC20(_usdc);
        riskManager = IRiskManager(_riskManager);
        positionManager = IPositionManager(_positionManager);
        treasuryManager = ITreasuryManager(_treasuryManager);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BACKEND_SIGNER_ROLE, _backendSigner);
        _grantRole(KEEPER_ROLE, _backendSigner); // Keeper can execute tap-to-trade orders
    }

    /**
     * @notice Authorize a session key for tap-to-trade
     * @param sessionKeyAddress Address of the session key to authorize
     * @param duration Duration in seconds (max 2 hours)
     * @param authSignature Signature from trader authorizing this session key
     */
    function authorizeSessionKey(address sessionKeyAddress, uint256 duration, bytes calldata authSignature) external {
        require(sessionKeyAddress != address(0), "TapToTradeExecutor: Invalid session key");
        require(duration > 0 && duration <= MAX_SESSION_DURATION, "TapToTradeExecutor: Invalid duration");

        // Calculate expiry
        uint256 expiresAt = block.timestamp + duration;

        // Verify authorization signature
        // Message format must match frontend: keccak256(toHex("Authorize session key {address} for Tethra Tap-to-Trade until {timestamp}"))
        bytes32 messageHash = keccak256(
            abi.encodePacked("Authorize session key ", sessionKeyAddress, " for Tethra Tap-to-Trade until ", expiresAt)
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(authSignature);

        require(signer == msg.sender, "TapToTradeExecutor: Invalid authorization signature");

        // Store session key
        sessionKeys[msg.sender][sessionKeyAddress] =
            SessionKey({keyAddress: sessionKeyAddress, expiresAt: expiresAt, isActive: true});

        emit SessionKeyAuthorized(msg.sender, sessionKeyAddress, expiresAt);
    }

    /**
     * @notice Revoke a session key
     * @param sessionKeyAddress Address of the session key to revoke
     */
    function revokeSessionKey(address sessionKeyAddress) external {
        require(sessionKeys[msg.sender][sessionKeyAddress].isActive, "TapToTradeExecutor: Session key not active");

        sessionKeys[msg.sender][sessionKeyAddress].isActive = false;

        emit SessionKeyRevoked(msg.sender, sessionKeyAddress);
    }

    /**
     * @notice Check if a session key is valid for a trader
     * @param trader Trader address
     * @param sessionKeyAddress Session key address
     * @return bool True if session key is valid
     */
    function isSessionKeyValid(address trader, address sessionKeyAddress) public view returns (bool) {
        SessionKey memory session = sessionKeys[trader][sessionKeyAddress];
        return session.isActive && block.timestamp < session.expiresAt;
    }

    /**
     * @notice Execute tap-to-trade order via meta-transaction (supports session keys!)
     * @param trader The actual trader address
     * @param symbol Asset symbol (BTC, ETH, etc)
     * @param isLong True for long, false for short
     * @param collateral Collateral amount in USDC (6 decimals)
     * @param leverage Leverage multiplier
     * @param signedPrice Backend-signed price data
     * @param userSignature Signature from trader OR authorized session key
     */
    function executeTapToTrade(
        address trader,
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        SignedPrice calldata signedPrice,
        bytes calldata userSignature
    ) external nonReentrant onlyRole(KEEPER_ROLE) returns (uint256 positionId) {
        // Verify user signature (can be from trader OR authorized session key)
        bytes32 messageHash =
            keccak256(abi.encodePacked(trader, symbol, isLong, collateral, leverage, metaNonces[trader], address(this)));

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(userSignature);

        // Check if signer is trader OR valid session key
        bool isValidSignature = (signer == trader) || isSessionKeyValid(trader, signer);

        require(isValidSignature, "TapToTradeExecutor: Invalid user signature");

        // Increment nonce to prevent replay
        metaNonces[trader]++;

        // Verify price signature and freshness
        _verifySignedPrice(signedPrice);

        // Validate trade parameters via RiskManager
        require(
            riskManager.validateTrade(trader, symbol, leverage, collateral, isLong),
            "TapToTradeExecutor: Trade validation failed"
        );

        // Collect collateral from TRADER (not keeper!)
        require(usdc.transferFrom(trader, address(treasuryManager), collateral), "TapToTradeExecutor: Transfer failed");

        // Create position via PositionManager (use trader address)
        positionId = positionManager.createPosition(trader, symbol, isLong, collateral, leverage, signedPrice.price);

        emit MetaTransactionExecuted(trader, msg.sender, metaNonces[trader] - 1);
        emit TapToTradeOrderExecuted(
            positionId, trader, symbol, isLong, collateral, leverage, signedPrice.price, signer
        );
    }

    /**
     * @notice Execute tap-to-trade order WITHOUT signature verification (keeper-only)
     * @dev This allows fully gasless execution where backend validates signatures off-chain
     * @param trader The actual trader address
     * @param symbol Asset symbol (BTC, ETH, etc)
     * @param isLong True for long, false for short
     * @param collateral Collateral amount in USDC (6 decimals)
     * @param leverage Leverage multiplier
     * @param signedPrice Backend-signed price data
     */
    function executeTapToTradeByKeeper(
        address trader,
        string calldata symbol,
        bool isLong,
        uint256 collateral,
        uint256 leverage,
        SignedPrice calldata signedPrice
    ) external nonReentrant onlyRole(KEEPER_ROLE) returns (uint256 positionId) {
        // Skip nonce increment - keeper executes without meta-transaction
        // No signature verification needed - keeper is trusted

        // Verify price signature and freshness
        _verifySignedPrice(signedPrice);

        // Validate trade parameters via RiskManager
        require(
            riskManager.validateTrade(trader, symbol, leverage, collateral, isLong),
            "TapToTradeExecutor: Trade validation failed"
        );

        // Collect collateral from TRADER (not keeper!)
        require(usdc.transferFrom(trader, address(treasuryManager), collateral), "TapToTradeExecutor: Transfer failed");

        // Create position via PositionManager (use trader address)
        positionId = positionManager.createPosition(trader, symbol, isLong, collateral, leverage, signedPrice.price);

        emit TapToTradeOrderExecuted(
            positionId, trader, symbol, isLong, collateral, leverage, signedPrice.price, msg.sender
        );
    }

    /**
     * @notice Verify backend-signed price data
     * @param signedPrice Signed price data from backend
     */
    function _verifySignedPrice(SignedPrice calldata signedPrice) internal view {
        // Check price freshness
        require(block.timestamp <= signedPrice.timestamp + PRICE_VALIDITY_WINDOW, "TapToTradeExecutor: Price too old");

        // Reconstruct message hash
        bytes32 messageHash = keccak256(abi.encodePacked(signedPrice.symbol, signedPrice.price, signedPrice.timestamp));

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(signedPrice.signature);

        require(hasRole(BACKEND_SIGNER_ROLE, signer), "TapToTradeExecutor: Invalid price signature");
    }

    /**
     * @notice Update fee structure (admin only)
     * @param _tradingFeeBps New trading fee in basis points
     */
    function updateFees(uint256 _tradingFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_tradingFeeBps <= 100, "TapToTradeExecutor: Fee too high"); // Max 1%
        tradingFeeBps = _tradingFeeBps;
    }

    /**
     * @notice Update RiskManager address (admin only)
     * @param _riskManager New RiskManager address
     */
    function updateRiskManager(address _riskManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_riskManager != address(0), "TapToTradeExecutor: Invalid address");
        riskManager = IRiskManager(_riskManager);
    }
}

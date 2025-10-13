// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title USDCPaymaster
 * @notice ERC-4337 Paymaster that accepts USDC for gas payments
 * @dev Works with Privy embedded wallets and AA infrastructure
 *
 * Flow:
 * 1. User initiates transaction with USDC balance
 * 2. Paymaster validates user has enough USDC
 * 3. Paymaster pays gas in native token (ETH/Base)
 * 4. Paymaster collects equivalent USDC from user
 * 5. Protocol swaps USDC to native token periodically
 */
contract USDCPaymaster is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    // Exchange rate: USDC per 1 ETH (6 decimals)
    // Example: If 1 ETH = $3000, rate = 3000_000000 (3000 USDC with 6 decimals)
    uint256 public usdcPerEth;

    // Premium charged on top of gas cost (in basis points)
    // Example: 1000 = 10% premium
    uint256 public premiumBps = 1000;

    // Whitelist for allowed executors (MarketExecutor, LimitExecutor)
    mapping(address => bool) public allowedExecutors;

    // User USDC deposits for gas
    mapping(address => uint256) public userDeposits;

    // Total USDC collected from users
    uint256 public totalUsdcCollected;

    // Minimum USDC deposit required
    uint256 public minDeposit = 10_000000; // 10 USDC

    // Events
    event DepositReceived(address indexed user, uint256 amount, uint256 timestamp);

    event GasPaymentProcessed(address indexed user, uint256 gasUsed, uint256 usdcCharged, uint256 timestamp);

    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate, uint256 timestamp);

    event PremiumUpdated(uint256 oldPremium, uint256 newPremium, uint256 timestamp);

    event ExecutorStatusUpdated(address indexed executor, bool allowed, uint256 timestamp);

    event UsdcWithdrawn(address indexed to, uint256 amount, uint256 timestamp);

    event UserWithdrawal(address indexed user, uint256 amount, uint256 timestamp);

    constructor(address _usdc, uint256 _usdcPerEth) Ownable(msg.sender) {
        require(_usdc != address(0), "USDCPaymaster: Invalid USDC");
        require(_usdcPerEth > 0, "USDCPaymaster: Invalid rate");

        usdc = IERC20(_usdc);
        usdcPerEth = _usdcPerEth;
    }

    /**
     * @notice Deposit USDC to pay for future gas
     * @param amount Amount of USDC to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount >= minDeposit, "USDCPaymaster: Below minimum deposit");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        userDeposits[msg.sender] += amount;

        emit DepositReceived(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Withdraw unused USDC deposit
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "USDCPaymaster: Invalid amount");
        require(userDeposits[msg.sender] >= amount, "USDCPaymaster: Insufficient balance");

        userDeposits[msg.sender] -= amount;

        usdc.safeTransfer(msg.sender, amount);

        emit UserWithdrawal(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Process gas payment in USDC
     * @param user User address paying for gas
     * @param gasUsed Amount of gas used (in wei)
     * @return usdcCharged Amount of USDC charged to user
     */
    function processGasPayment(address user, uint256 gasUsed) external nonReentrant returns (uint256 usdcCharged) {
        require(allowedExecutors[msg.sender], "USDCPaymaster: Not allowed executor");
        require(user != address(0), "USDCPaymaster: Invalid user");
        require(gasUsed > 0, "USDCPaymaster: No gas used");

        // Calculate USDC amount needed
        // gasUsed is in wei (18 decimals)
        // usdcPerEth is in 6 decimals
        // Result should be in 6 decimals (USDC)
        usdcCharged = (gasUsed * usdcPerEth) / 1e18;

        // Add premium
        uint256 premium = (usdcCharged * premiumBps) / 10000;
        usdcCharged += premium;

        // Check user has enough USDC deposit
        require(userDeposits[user] >= usdcCharged, "USDCPaymaster: Insufficient deposit");

        // Deduct from user deposit
        userDeposits[user] -= usdcCharged;

        // Track total collected
        totalUsdcCollected += usdcCharged;

        emit GasPaymentProcessed(user, gasUsed, usdcCharged, block.timestamp);
    }

    /**
     * @notice Validate user can pay for estimated gas
     * @param user User address
     * @param estimatedGas Estimated gas for transaction
     * @return canPay Whether user has enough USDC
     */
    function validateGasPayment(address user, uint256 estimatedGas) external view returns (bool canPay) {
        if (user == address(0) || estimatedGas == 0) {
            return false;
        }

        // Calculate required USDC
        uint256 usdcRequired = (estimatedGas * usdcPerEth) / 1e18;
        uint256 premium = (usdcRequired * premiumBps) / 10000;
        usdcRequired += premium;

        return userDeposits[user] >= usdcRequired;
    }

    /**
     * @notice Calculate USDC cost for gas amount
     * @param gasAmount Gas amount in wei
     * @return usdcCost USDC cost (6 decimals)
     */
    function calculateUsdcCost(uint256 gasAmount) public view returns (uint256 usdcCost) {
        usdcCost = (gasAmount * usdcPerEth) / 1e18;
        uint256 premium = (usdcCost * premiumBps) / 10000;
        usdcCost += premium;
    }

    /**
     * @notice Update USDC/ETH exchange rate (owner only)
     * @param _usdcPerEth New rate (USDC per 1 ETH, 6 decimals)
     */
    function updateExchangeRate(uint256 _usdcPerEth) external onlyOwner {
        require(_usdcPerEth > 0, "USDCPaymaster: Invalid rate");

        uint256 oldRate = usdcPerEth;
        usdcPerEth = _usdcPerEth;

        emit ExchangeRateUpdated(oldRate, _usdcPerEth, block.timestamp);
    }

    /**
     * @notice Update premium percentage (owner only)
     * @param _premiumBps New premium in basis points
     */
    function updatePremium(uint256 _premiumBps) external onlyOwner {
        require(_premiumBps <= 5000, "USDCPaymaster: Premium too high"); // Max 50%

        uint256 oldPremium = premiumBps;
        premiumBps = _premiumBps;

        emit PremiumUpdated(oldPremium, _premiumBps, block.timestamp);
    }

    /**
     * @notice Update minimum deposit (owner only)
     * @param _minDeposit New minimum deposit
     */
    function updateMinDeposit(uint256 _minDeposit) external onlyOwner {
        require(_minDeposit > 0, "USDCPaymaster: Invalid amount");
        minDeposit = _minDeposit;
    }

    /**
     * @notice Set executor whitelist status (owner only)
     * @param executor Executor address
     * @param allowed Whether executor is allowed
     */
    function setExecutorStatus(address executor, bool allowed) external onlyOwner {
        require(executor != address(0), "USDCPaymaster: Invalid executor");

        allowedExecutors[executor] = allowed;

        emit ExecutorStatusUpdated(executor, allowed, block.timestamp);
    }

    /**
     * @notice Withdraw collected USDC (owner only)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawUsdc(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "USDCPaymaster: Invalid address");
        require(amount > 0, "USDCPaymaster: Invalid amount");
        require(amount <= totalUsdcCollected, "USDCPaymaster: Exceeds collected amount");

        totalUsdcCollected -= amount;

        usdc.safeTransfer(to, amount);

        emit UsdcWithdrawn(to, amount, block.timestamp);
    }

    /**
     * @notice Get user deposit balance
     * @param user User address
     * @return balance User's USDC deposit
     */
    function getUserDeposit(address user) external view returns (uint256 balance) {
        return userDeposits[user];
    }

    /**
     * @notice Get total USDC balance in paymaster
     * @return Total USDC balance
     */
    function getTotalBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Get current exchange rate and premium
     * @return rate USDC per ETH
     * @return premium Premium in basis points
     */
    function getRateInfo() external view returns (uint256 rate, uint256 premium) {
        return (usdcPerEth, premiumBps);
    }

    /**
     * @notice Fund paymaster with native token for gas (owner only)
     * @dev Owner deposits ETH/native token to pay for user transactions
     */
    function fundPaymaster() external payable onlyOwner {
        require(msg.value > 0, "USDCPaymaster: No value sent");
    }

    /**
     * @notice Withdraw native token (owner only)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "USDCPaymaster: Invalid address");
        require(amount > 0, "USDCPaymaster: Invalid amount");
        require(address(this).balance >= amount, "USDCPaymaster: Insufficient balance");

        to.transfer(amount);
    }

    /**
     * @notice Emergency withdraw any ERC20 (owner only)
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "USDCPaymaster: Invalid token");
        require(to != address(0), "USDCPaymaster: Invalid address");
        require(amount > 0, "USDCPaymaster: Invalid amount");

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Receive native token
     */
    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TreasuryManager
 * @notice Central treasury for managing all USDC flows
 * @dev Handles fees, collateral, profits, and liquidity pool
 */
contract TreasuryManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC20 public immutable usdc;

    // Treasury balances
    uint256 public totalCollateral; // Total trader collateral held
    uint256 public totalFees; // Accumulated trading fees
    uint256 public totalExecutionFees; // Accumulated execution fees for keepers
    uint256 public liquidityPool; // Protocol liquidity pool

    // Protocol fee distribution (in basis points, total = 10000)
    uint256 public feeToLiquidity = 5000; // 50% to liquidity pool
    uint256 public feeToStaking = 3000; // 30% to staking rewards
    uint256 public feeToTreasury = 2000; // 20% to protocol treasury

    // Addresses
    address public stakingRewards;
    address public protocolTreasury;

    // Statistics tracking
    uint256 public totalFeesCollected;
    uint256 public totalProfitsDistributed;
    uint256 public totalCollateralRefunded;
    uint256 public totalKeeperFeesPaid;
    uint256 public totalRelayerFeesPaid;

    // Events
    event FeeCollected(address indexed from, uint256 amount, uint256 timestamp);

    event ExecutionFeeCollected(address indexed from, uint256 amount, uint256 timestamp);

    event CollateralRefunded(address indexed to, uint256 amount, uint256 timestamp);

    event ProfitDistributed(address indexed to, uint256 amount, uint256 timestamp);

    event KeeperFeePaid(address indexed keeper, uint256 amount, uint256 timestamp);

    event RelayerFeePaid(address indexed relayer, uint256 amount, uint256 timestamp);

    event FeeCollectedWithSplit(address indexed from, uint256 totalAmount, uint256 relayerAmount, uint256 treasuryAmount, uint256 timestamp);

    event LiquidityAdded(address indexed provider, uint256 amount, uint256 timestamp);

    event LiquidityRemoved(address indexed provider, uint256 amount, uint256 timestamp);

    event FeesDistributed(uint256 toLiquidity, uint256 toStaking, uint256 toTreasury, uint256 timestamp);

    event FeeDistributionUpdated(uint256 feeToLiquidity, uint256 feeToStaking, uint256 feeToTreasury);

    event AddressesUpdated(address stakingRewards, address protocolTreasury);

    constructor(address _usdc, address _stakingRewards, address _protocolTreasury) {
        require(_usdc != address(0), "TreasuryManager: Invalid USDC");
        require(_stakingRewards != address(0), "TreasuryManager: Invalid staking");
        require(_protocolTreasury != address(0), "TreasuryManager: Invalid treasury");

        usdc = IERC20(_usdc);
        stakingRewards = _stakingRewards;
        protocolTreasury = _protocolTreasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Collect trading fee from a trader
     * @param from Trader address (for event tracking)
     * @param amount Fee amount in USDC
     */
    function collectFee(address from, uint256 amount) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(amount > 0, "TreasuryManager: Invalid amount");

        totalFees += amount;
        totalFeesCollected += amount;

        emit FeeCollected(from, amount, block.timestamp);
    }

    /**
     * @notice Collect trading fee with relayer split
     * @dev Splits fee: 20% to relayer (0.01% of size), 80% to treasury (0.04% of size)
     * @param from Trader address (for event tracking)
     * @param relayer Relayer address to receive their portion
     * @param totalFeeAmount Total fee amount (0.05% of position size)
     */
    function collectFeeWithRelayerSplit(address from, address relayer, uint256 totalFeeAmount)
        external
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
    {
        require(totalFeeAmount > 0, "TreasuryManager: Invalid amount");
        require(relayer != address(0), "TreasuryManager: Invalid relayer");

        // Split: 20% to relayer, 80% to treasury
        // 0.01% / 0.05% = 20%
        uint256 relayerAmount = (totalFeeAmount * 2000) / 10000; // 20%
        uint256 treasuryAmount = totalFeeAmount - relayerAmount; // 80%

        // Add treasury portion to fees
        totalFees += treasuryAmount;
        totalFeesCollected += treasuryAmount;

        // Track relayer fees
        totalRelayerFeesPaid += relayerAmount;

        // Pay relayer immediately
        usdc.safeTransfer(relayer, relayerAmount);

        emit FeeCollectedWithSplit(from, totalFeeAmount, relayerAmount, treasuryAmount, block.timestamp);
        emit RelayerFeePaid(relayer, relayerAmount, block.timestamp);
    }

    /**
     * @notice Collect execution fee for keeper orders
     * @param from Trader address
     * @param amount Execution fee amount
     */
    function collectExecutionFee(address from, uint256 amount) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(amount > 0, "TreasuryManager: Invalid amount");

        totalExecutionFees += amount;

        emit ExecutionFeeCollected(from, amount, block.timestamp);
    }

    /**
     * @notice Refund collateral to trader
     * @param to Trader address
     * @param amount Collateral amount to refund
     */
    function refundCollateral(address to, uint256 amount) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(to != address(0), "TreasuryManager: Invalid address");
        require(amount > 0, "TreasuryManager: Invalid amount");
        require(usdc.balanceOf(address(this)) >= amount, "TreasuryManager: Insufficient balance");

        totalCollateralRefunded += amount;

        usdc.safeTransfer(to, amount);

        emit CollateralRefunded(to, amount, block.timestamp);
    }

    /**
     * @notice Distribute profit to trader
     * @param to Trader address
     * @param amount Profit amount
     */
    function distributeProfit(address to, uint256 amount) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(to != address(0), "TreasuryManager: Invalid address");
        require(amount > 0, "TreasuryManager: Invalid amount");
        require(liquidityPool >= amount, "TreasuryManager: Insufficient liquidity");

        liquidityPool -= amount;
        totalProfitsDistributed += amount;

        usdc.safeTransfer(to, amount);

        emit ProfitDistributed(to, amount, block.timestamp);
    }

    /**
     * @notice Pay execution fee to keeper
     * @param keeper Keeper address
     * @param amount Execution fee amount
     */
    function payKeeperFee(address keeper, uint256 amount) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(keeper != address(0), "TreasuryManager: Invalid keeper");
        require(amount > 0, "TreasuryManager: Invalid amount");
        require(totalExecutionFees >= amount, "TreasuryManager: Insufficient execution fees");

        totalExecutionFees -= amount;
        totalKeeperFeesPaid += amount;

        usdc.safeTransfer(keeper, amount);

        emit KeeperFeePaid(keeper, amount, block.timestamp);
    }

    /**
     * @notice Add liquidity to the pool
     * @param amount Amount of USDC to add
     */
    function addLiquidity(uint256 amount) external nonReentrant {
        require(amount > 0, "TreasuryManager: Invalid amount");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        liquidityPool += amount;

        emit LiquidityAdded(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Remove liquidity from the pool (admin only)
     * @param to Address to receive liquidity
     * @param amount Amount to remove
     */
    function removeLiquidity(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "TreasuryManager: Invalid address");
        require(amount > 0, "TreasuryManager: Invalid amount");
        require(liquidityPool >= amount, "TreasuryManager: Insufficient liquidity");

        liquidityPool -= amount;

        usdc.safeTransfer(to, amount);

        emit LiquidityRemoved(to, amount, block.timestamp);
    }

    /**
     * @notice Distribute accumulated fees to stakeholders
     * @dev Distributes fees according to fee distribution ratios
     */
    function distributeFees() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(totalFees > 0, "TreasuryManager: No fees to distribute");

        uint256 feesToDistribute = totalFees;
        totalFees = 0;

        // Calculate distributions
        uint256 toLiquidity = (feesToDistribute * feeToLiquidity) / 10000;
        uint256 toStaking = (feesToDistribute * feeToStaking) / 10000;
        uint256 toTreasury = feesToDistribute - toLiquidity - toStaking;

        // Distribute to liquidity pool
        if (toLiquidity > 0) {
            liquidityPool += toLiquidity;
        }

        // Distribute to staking rewards
        if (toStaking > 0 && stakingRewards != address(0)) {
            usdc.safeTransfer(stakingRewards, toStaking);
        }

        // Distribute to protocol treasury
        if (toTreasury > 0 && protocolTreasury != address(0)) {
            usdc.safeTransfer(protocolTreasury, toTreasury);
        }

        emit FeesDistributed(toLiquidity, toStaking, toTreasury, block.timestamp);
    }

    /**
     * @notice Update fee distribution ratios (admin only)
     * @param _feeToLiquidity Basis points to liquidity pool
     * @param _feeToStaking Basis points to staking rewards
     * @param _feeToTreasury Basis points to protocol treasury
     */
    function updateFeeDistribution(uint256 _feeToLiquidity, uint256 _feeToStaking, uint256 _feeToTreasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_feeToLiquidity + _feeToStaking + _feeToTreasury == 10000, "TreasuryManager: Must sum to 10000 bps");

        feeToLiquidity = _feeToLiquidity;
        feeToStaking = _feeToStaking;
        feeToTreasury = _feeToTreasury;

        emit FeeDistributionUpdated(_feeToLiquidity, _feeToStaking, _feeToTreasury);
    }

    /**
     * @notice Update stakeholder addresses (admin only)
     * @param _stakingRewards New staking rewards address
     * @param _protocolTreasury New protocol treasury address
     */
    function updateAddresses(address _stakingRewards, address _protocolTreasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_stakingRewards != address(0)) {
            stakingRewards = _stakingRewards;
        }
        if (_protocolTreasury != address(0)) {
            protocolTreasury = _protocolTreasury;
        }

        emit AddressesUpdated(_stakingRewards, _protocolTreasury);
    }

    /**
     * @notice Get total USDC balance held by treasury
     * @return Total USDC balance
     */
    function getTotalBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Get available liquidity for trader profits
     * @return Available liquidity
     */
    function getAvailableLiquidity() external view returns (uint256) {
        return liquidityPool;
    }

    /**
     * @notice Get pending fees to be distributed
     * @return Pending fees
     */
    function getPendingFees() external view returns (uint256) {
        return totalFees;
    }

    /**
     * @notice Get pending execution fees for keepers
     * @return Pending execution fees
     */
    function getPendingExecutionFees() external view returns (uint256) {
        return totalExecutionFees;
    }

    /**
     * @notice Get treasury statistics
     * @return feesCollected Total fees collected
     * @return profitsDistributed Total profits paid to traders
     * @return collateralRefunded Total collateral refunded
     * @return keeperFeesPaid Total fees paid to keepers
     * @return relayerFeesPaid Total fees paid to relayers
     */
    function getStatistics()
        external
        view
        returns (
            uint256 feesCollected,
            uint256 profitsDistributed,
            uint256 collateralRefunded,
            uint256 keeperFeesPaid,
            uint256 relayerFeesPaid
        )
    {
        return (totalFeesCollected, totalProfitsDistributed, totalCollateralRefunded, totalKeeperFeesPaid, totalRelayerFeesPaid);
    }

    /**
     * @notice Get fee distribution ratios
     * @return toLiquidity Basis points to liquidity
     * @return toStaking Basis points to staking
     * @return toTreasury Basis points to treasury
     */
    function getFeeDistribution() external view returns (uint256 toLiquidity, uint256 toStaking, uint256 toTreasury) {
        return (feeToLiquidity, feeToStaking, feeToTreasury);
    }

    /**
     * @notice Emergency withdraw (admin only, for emergencies)
     * @param token Token address (use address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "TreasuryManager: Invalid address");
        require(amount > 0, "TreasuryManager: Invalid amount");

        if (token == address(0)) {
            // Withdraw ETH
            payable(to).transfer(amount);
        } else {
            // Withdraw ERC20
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Receive ETH (for native gas if needed)
     */
    receive() external payable {}
}

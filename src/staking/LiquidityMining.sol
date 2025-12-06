// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidityMining
 * @notice Provide USDC liquidity to earn TETRA token rewards
 * @dev Liquidity providers earn TETRA based on their share of the pool
 */
contract LiquidityMining is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC20 public immutable tetraToken;

    // Liquidity provider info
    struct ProviderInfo {
        uint256 amount; // Amount of USDC provided
        uint256 rewardDebt; // Reward debt for calculations
        uint256 pendingRewards; // Pending TETRA rewards
        uint256 depositedAt; // Timestamp when deposited
        uint256 lastClaimAt; // Last reward claim timestamp
    }

    // User address => ProviderInfo
    mapping(address => ProviderInfo) public providers;

    // Total USDC liquidity provided
    uint256 public totalLiquidity;

    // Accumulated TETRA per share (scaled by 1e12 for precision)
    uint256 public accTetraPerShare;

    // Total TETRA rewards distributed
    uint256 public totalRewardsDistributed;

    // TETRA emission rate per block (e.g., 1 TETRA per block)
    uint256 public tetraPerBlock = 1e18;

    // Last block where rewards were calculated
    uint256 public lastRewardBlock;

    // Minimum deposit amount (100 USDC)
    uint256 public minDeposit = 100_000000;

    // Lock period (14 days)
    uint256 public lockPeriod = 14 days;

    // Early withdrawal penalty (15%)
    uint256 public earlyWithdrawPenaltyBps = 1500;

    // Events
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 timestamp);

    event LiquidityRemoved(address indexed provider, uint256 amount, uint256 penalty, uint256 timestamp);

    event RewardsClaimed(address indexed provider, uint256 amount, uint256 timestamp);

    event EmissionRateUpdated(uint256 oldRate, uint256 newRate, uint256 timestamp);

    event ParametersUpdated(uint256 minDeposit, uint256 lockPeriod, uint256 earlyWithdrawPenaltyBps);

    constructor(address _usdc, address _tetraToken) Ownable(msg.sender) {
        require(_usdc != address(0), "LiquidityMining: Invalid USDC");
        require(_tetraToken != address(0), "LiquidityMining: Invalid TETRA");

        usdc = IERC20(_usdc);
        tetraToken = IERC20(_tetraToken);

        lastRewardBlock = block.number;
    }

    /**
     * @notice Add USDC liquidity to earn TETRA rewards
     * @param amount Amount of USDC to deposit
     */
    function addLiquidity(uint256 amount) external nonReentrant {
        require(amount >= minDeposit, "LiquidityMining: Below minimum deposit");

        // Update pool rewards before adding liquidity
        _updatePool();

        ProviderInfo storage provider = providers[msg.sender];

        // Update pending rewards before changing liquidity
        _updateRewards(msg.sender);

        // Transfer USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Update provider info
        if (provider.amount == 0) {
            provider.depositedAt = block.timestamp;
        }
        provider.amount += amount;
        provider.rewardDebt = (provider.amount * accTetraPerShare) / 1e12;

        totalLiquidity += amount;

        emit LiquidityAdded(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Remove USDC liquidity
     * @param amount Amount of USDC to withdraw
     */
    function removeLiquidity(uint256 amount) external nonReentrant {
        ProviderInfo storage provider = providers[msg.sender];
        require(amount > 0, "LiquidityMining: Invalid amount");
        require(provider.amount >= amount, "LiquidityMining: Insufficient liquidity");

        // Update pool rewards before removing liquidity
        _updatePool();

        // Update pending rewards before changing liquidity
        _updateRewards(msg.sender);

        // Calculate penalty if withdrawing early
        uint256 penalty = 0;
        bool isEarlyWithdraw = block.timestamp < provider.depositedAt + lockPeriod;

        if (isEarlyWithdraw) {
            penalty = (amount * earlyWithdrawPenaltyBps) / 10000;
        }

        // Update provider info
        provider.amount -= amount;
        provider.rewardDebt = (provider.amount * accTetraPerShare) / 1e12;

        totalLiquidity -= amount;

        // Transfer USDC back to user (minus penalty if applicable)
        uint256 amountToReturn = amount - penalty;
        usdc.safeTransfer(msg.sender, amountToReturn);

        // Penalty stays in the pool (benefits other LPs)
        // Or can be sent to treasury
        if (penalty > 0) {
            usdc.safeTransfer(owner(), penalty);
        }

        emit LiquidityRemoved(msg.sender, amount, penalty, block.timestamp);
    }

    /**
     * @notice Claim pending TETRA rewards
     */
    function claimRewards() external nonReentrant {
        // Update pool rewards
        _updatePool();

        // Update user rewards
        _updateRewards(msg.sender);

        ProviderInfo storage provider = providers[msg.sender];
        uint256 pending = provider.pendingRewards;

        require(pending > 0, "LiquidityMining: No rewards to claim");

        provider.pendingRewards = 0;
        provider.lastClaimAt = block.timestamp;

        totalRewardsDistributed += pending;

        tetraToken.safeTransfer(msg.sender, pending);

        emit RewardsClaimed(msg.sender, pending, block.timestamp);
    }

    /**
     * @notice Update pool rewards
     */
    function _updatePool() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (totalLiquidity == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 blocksSinceLastReward = block.number - lastRewardBlock;
        uint256 tetraReward = blocksSinceLastReward * tetraPerBlock;

        accTetraPerShare += (tetraReward * 1e12) / totalLiquidity;
        lastRewardBlock = block.number;
    }

    /**
     * @notice Update rewards for a provider
     * @param provider Provider address
     */
    function _updateRewards(address provider) internal {
        ProviderInfo storage providerInfo = providers[provider];

        if (providerInfo.amount > 0) {
            uint256 pending = (providerInfo.amount * accTetraPerShare) / 1e12 - providerInfo.rewardDebt;
            if (pending > 0) {
                providerInfo.pendingRewards += pending;
            }
        }
    }

    /**
     * @notice Get pending rewards for a provider
     * @param provider Provider address
     * @return pending Pending TETRA rewards
     */
    function getPendingRewards(address provider) external view returns (uint256 pending) {
        ProviderInfo memory providerInfo = providers[provider];

        uint256 _accTetraPerShare = accTetraPerShare;

        if (block.number > lastRewardBlock && totalLiquidity > 0) {
            uint256 blocksSinceLastReward = block.number - lastRewardBlock;
            uint256 tetraReward = blocksSinceLastReward * tetraPerBlock;
            _accTetraPerShare += (tetraReward * 1e12) / totalLiquidity;
        }

        if (providerInfo.amount > 0) {
            pending = providerInfo.pendingRewards + (providerInfo.amount * _accTetraPerShare) / 1e12
                - providerInfo.rewardDebt;
        }
    }

    /**
     * @notice Get provider info
     * @param provider Provider address
     * @return amount Liquidity provided
     * @return pendingRewards Pending TETRA rewards
     * @return depositedAt Deposit timestamp
     * @return canWithdrawWithoutPenalty Whether can withdraw without penalty
     */
    function getProviderInfo(address provider)
        external
        view
        returns (uint256 amount, uint256 pendingRewards, uint256 depositedAt, bool canWithdrawWithoutPenalty)
    {
        ProviderInfo memory providerInfo = providers[provider];

        uint256 _accTetraPerShare = accTetraPerShare;

        if (block.number > lastRewardBlock && totalLiquidity > 0) {
            uint256 blocksSinceLastReward = block.number - lastRewardBlock;
            uint256 tetraReward = blocksSinceLastReward * tetraPerBlock;
            _accTetraPerShare += (tetraReward * 1e12) / totalLiquidity;
        }

        uint256 pending =
            providerInfo.pendingRewards + (providerInfo.amount * _accTetraPerShare) / 1e12 - providerInfo.rewardDebt;

        return (
            providerInfo.amount,
            pending,
            providerInfo.depositedAt,
            block.timestamp >= providerInfo.depositedAt + lockPeriod
        );
    }

    /**
     * @notice Get liquidity mining statistics
     * @return _totalLiquidity Total USDC liquidity
     * @return _totalRewardsDistributed Total TETRA distributed
     * @return _tetraPerBlock TETRA emission per block
     * @return _accTetraPerShare Accumulated TETRA per share
     */
    function getMiningStats()
        external
        view
        returns (
            uint256 _totalLiquidity,
            uint256 _totalRewardsDistributed,
            uint256 _tetraPerBlock,
            uint256 _accTetraPerShare
        )
    {
        return (totalLiquidity, totalRewardsDistributed, tetraPerBlock, accTetraPerShare);
    }

    /**
     * @notice Calculate current APR
     * @return apr Annual Percentage Rate (scaled by 100, e.g., 2000 = 20%)
     */
    function calculateAPR() external view returns (uint256 apr) {
        if (totalLiquidity == 0) return 0;

        // Blocks per year (assuming ~12 second block time on Base)
        // 365 * 24 * 60 * 60 / 12 = 2,628,000 blocks/year
        uint256 blocksPerYear = 2628000;

        // Annual TETRA rewards
        uint256 annualTetraRewards = tetraPerBlock * blocksPerYear;

        // Assume TETRA = $1 for simplicity
        uint256 annualRewardsValue = annualTetraRewards / 1e18;

        // Total liquidity in USDC (6 decimals)
        uint256 totalLiquidityValue = totalLiquidity / 1e6;

        // APR = (annual rewards value / total liquidity value) * 10000
        apr = (annualRewardsValue * 10000) / totalLiquidityValue;
    }

    /**
     * @notice Update TETRA emission rate (owner only)
     * @param _tetraPerBlock New emission rate per block
     */
    function updateEmissionRate(uint256 _tetraPerBlock) external onlyOwner {
        require(_tetraPerBlock > 0, "LiquidityMining: Invalid rate");
        require(_tetraPerBlock <= 10e18, "LiquidityMining: Rate too high"); // Max 10 TETRA per block

        // Update pool before changing rate
        _updatePool();

        uint256 oldRate = tetraPerBlock;
        tetraPerBlock = _tetraPerBlock;

        emit EmissionRateUpdated(oldRate, _tetraPerBlock, block.timestamp);
    }

    /**
     * @notice Update mining parameters (owner only)
     * @param _minDeposit Minimum deposit amount
     * @param _lockPeriod Lock period in seconds
     * @param _earlyWithdrawPenaltyBps Early withdraw penalty in basis points
     */
    function updateParameters(uint256 _minDeposit, uint256 _lockPeriod, uint256 _earlyWithdrawPenaltyBps)
        external 
        onlyOwner
    {
        require(_minDeposit > 0, "LiquidityMining: Invalid min deposit");
        require(_lockPeriod <= 90 days, "LiquidityMining: Lock too long");
        require(_earlyWithdrawPenaltyBps <= 2500, "LiquidityMining: Penalty too high"); // Max 25%

        minDeposit = _minDeposit;
        lockPeriod = _lockPeriod;
        earlyWithdrawPenaltyBps = _earlyWithdrawPenaltyBps;

        emit ParametersUpdated(_minDeposit, _lockPeriod, _earlyWithdrawPenaltyBps);
    }

    /**
     * @notice Deposit TETRA tokens for rewards (owner only)
     * @param amount Amount of TETRA to deposit
     */
    function depositRewardTokens(uint256 amount) external onlyOwner {
        require(amount > 0, "LiquidityMining: Invalid amount");

        tetraToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Emergency withdraw (owner only)
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "LiquidityMining: Invalid token");
        require(to != address(0), "LiquidityMining: Invalid address");
        require(amount > 0, "LiquidityMining: Invalid amount");

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Manually update pool (anyone can call)
     * @dev Useful for keeping rewards up to date
     */
    function updatePool() external {
        _updatePool();
    }
}

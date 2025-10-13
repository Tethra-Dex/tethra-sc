// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TethraStaking
 * @notice Stake TETRA tokens to earn USDC rewards from protocol fees
 * @dev 30% of protocol trading fees are distributed to TETRA stakers
 */
contract TethraStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable tetraToken;
    IERC20 public immutable usdc;

    // Staking info
    struct StakeInfo {
        uint256 amount; // Amount of TETRA staked
        uint256 rewardDebt; // Reward debt for calculations
        uint256 pendingRewards; // Pending USDC rewards
        uint256 stakedAt; // Timestamp when staked
        uint256 lastClaimAt; // Last reward claim timestamp
    }

    // User address => StakeInfo
    mapping(address => StakeInfo) public stakes;

    // Total TETRA staked
    uint256 public totalStaked;

    // Accumulated USDC per share (scaled by 1e12 for precision)
    uint256 public accUsdcPerShare;

    // Total USDC rewards distributed
    uint256 public totalRewardsDistributed;

    // Minimum stake amount (1 TETRA)
    uint256 public minStakeAmount = 1e18;

    // Lock period (7 days)
    uint256 public lockPeriod = 7 days;

    // Early unstake penalty (10%)
    uint256 public earlyUnstakePenaltyBps = 1000;

    // Events
    event Staked(address indexed user, uint256 amount, uint256 timestamp);

    event Unstaked(address indexed user, uint256 amount, uint256 penalty, uint256 timestamp);

    event RewardsClaimed(address indexed user, uint256 amount, uint256 timestamp);

    event RewardsAdded(uint256 amount, uint256 timestamp);

    event ParametersUpdated(uint256 minStakeAmount, uint256 lockPeriod, uint256 earlyUnstakePenaltyBps);

    constructor(address _tetraToken, address _usdc) Ownable(msg.sender) {
        require(_tetraToken != address(0), "TethraStaking: Invalid TETRA");
        require(_usdc != address(0), "TethraStaking: Invalid USDC");

        tetraToken = IERC20(_tetraToken);
        usdc = IERC20(_usdc);
    }

    /**
     * @notice Stake TETRA tokens
     * @param amount Amount of TETRA to stake
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount >= minStakeAmount, "TethraStaking: Below minimum stake");

        StakeInfo storage userStake = stakes[msg.sender];

        // Update pending rewards before changing stake
        _updateRewards(msg.sender);

        // Transfer TETRA from user
        tetraToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update stake info
        if (userStake.amount == 0) {
            userStake.stakedAt = block.timestamp;
        }
        userStake.amount += amount;
        userStake.rewardDebt = (userStake.amount * accUsdcPerShare) / 1e12;

        totalStaked += amount;

        emit Staked(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Unstake TETRA tokens
     * @param amount Amount of TETRA to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        require(amount > 0, "TethraStaking: Invalid amount");
        require(userStake.amount >= amount, "TethraStaking: Insufficient stake");

        // Update pending rewards before changing stake
        _updateRewards(msg.sender);

        // Calculate penalty if unstaking early
        uint256 penalty = 0;
        bool isEarlyUnstake = block.timestamp < userStake.stakedAt + lockPeriod;

        if (isEarlyUnstake) {
            penalty = (amount * earlyUnstakePenaltyBps) / 10000;
        }

        // Update stake info
        userStake.amount -= amount;
        userStake.rewardDebt = (userStake.amount * accUsdcPerShare) / 1e12;

        totalStaked -= amount;

        // Transfer TETRA back to user (minus penalty if applicable)
        uint256 amountToReturn = amount - penalty;
        tetraToken.safeTransfer(msg.sender, amountToReturn);

        // Penalty goes to protocol treasury (burned or redistributed)
        if (penalty > 0) {
            tetraToken.safeTransfer(owner(), penalty);
        }

        emit Unstaked(msg.sender, amount, penalty, block.timestamp);
    }

    /**
     * @notice Claim pending USDC rewards
     */
    function claimRewards() external nonReentrant {
        _updateRewards(msg.sender);

        StakeInfo storage userStake = stakes[msg.sender];
        uint256 pending = userStake.pendingRewards;

        require(pending > 0, "TethraStaking: No rewards to claim");

        userStake.pendingRewards = 0;
        userStake.lastClaimAt = block.timestamp;

        totalRewardsDistributed += pending;

        usdc.safeTransfer(msg.sender, pending);

        emit RewardsClaimed(msg.sender, pending, block.timestamp);
    }

    /**
     * @notice Add USDC rewards to be distributed (called by TreasuryManager)
     * @param amount Amount of USDC rewards to add
     */
    function addRewards(uint256 amount) external nonReentrant {
        require(amount > 0, "TethraStaking: Invalid amount");
        require(totalStaked > 0, "TethraStaking: No stakers");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Update accumulated USDC per share
        accUsdcPerShare += (amount * 1e12) / totalStaked;

        emit RewardsAdded(amount, block.timestamp);
    }

    /**
     * @notice Update rewards for a user
     * @param user User address
     */
    function _updateRewards(address user) internal {
        StakeInfo storage userStake = stakes[user];

        if (userStake.amount > 0) {
            uint256 pending = (userStake.amount * accUsdcPerShare) / 1e12 - userStake.rewardDebt;
            if (pending > 0) {
                userStake.pendingRewards += pending;
            }
        }
    }

    /**
     * @notice Get pending rewards for a user
     * @param user User address
     * @return pending Pending USDC rewards
     */
    function getPendingRewards(address user) external view returns (uint256 pending) {
        StakeInfo memory userStake = stakes[user];

        if (userStake.amount > 0) {
            pending = userStake.pendingRewards + (userStake.amount * accUsdcPerShare) / 1e12 - userStake.rewardDebt;
        }
    }

    /**
     * @notice Get user stake info
     * @param user User address
     * @return amount Staked amount
     * @return pendingRewards Pending USDC rewards
     * @return stakedAt Stake timestamp
     * @return canUnstakeWithoutPenalty Whether user can unstake without penalty
     */
    function getUserStakeInfo(address user)
        external
        view
        returns (uint256 amount, uint256 pendingRewards, uint256 stakedAt, bool canUnstakeWithoutPenalty)
    {
        StakeInfo memory userStake = stakes[user];

        uint256 pending = userStake.pendingRewards + (userStake.amount * accUsdcPerShare) / 1e12 - userStake.rewardDebt;

        return (userStake.amount, pending, userStake.stakedAt, block.timestamp >= userStake.stakedAt + lockPeriod);
    }

    /**
     * @notice Get staking statistics
     * @return _totalStaked Total TETRA staked
     * @return _totalRewardsDistributed Total USDC distributed
     * @return _accUsdcPerShare Accumulated USDC per share
     */
    function getStakingStats()
        external
        view
        returns (uint256 _totalStaked, uint256 _totalRewardsDistributed, uint256 _accUsdcPerShare)
    {
        return (totalStaked, totalRewardsDistributed, accUsdcPerShare);
    }

    /**
     * @notice Calculate current APR based on recent rewards
     * @param rewardsPer7Days USDC rewards distributed in last 7 days
     * @return apr Annual Percentage Rate (scaled by 100, e.g., 1500 = 15%)
     */
    function calculateAPR(uint256 rewardsPer7Days) external view returns (uint256 apr) {
        if (totalStaked == 0) return 0;

        // Annual rewards = weekly rewards * 52
        uint256 annualRewards = rewardsPer7Days * 52;

        // Assume TETRA = $1 for simplicity (can be made dynamic)
        uint256 totalStakedValue = totalStaked / 1e18; // Convert to token units

        // APR = (annual rewards / total staked value) * 10000
        apr = (annualRewards * 10000) / totalStakedValue;
    }

    /**
     * @notice Update staking parameters (owner only)
     * @param _minStakeAmount Minimum stake amount
     * @param _lockPeriod Lock period in seconds
     * @param _earlyUnstakePenaltyBps Early unstake penalty in basis points
     */
    function updateParameters(uint256 _minStakeAmount, uint256 _lockPeriod, uint256 _earlyUnstakePenaltyBps)
        external
        onlyOwner
    {
        require(_minStakeAmount > 0, "TethraStaking: Invalid min stake");
        require(_lockPeriod <= 90 days, "TethraStaking: Lock too long");
        require(_earlyUnstakePenaltyBps <= 2500, "TethraStaking: Penalty too high"); // Max 25%

        minStakeAmount = _minStakeAmount;
        lockPeriod = _lockPeriod;
        earlyUnstakePenaltyBps = _earlyUnstakePenaltyBps;

        emit ParametersUpdated(_minStakeAmount, _lockPeriod, _earlyUnstakePenaltyBps);
    }

    /**
     * @notice Emergency withdraw (owner only)
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "TethraStaking: Invalid token");
        require(to != address(0), "TethraStaking: Invalid address");
        require(amount > 0, "TethraStaking: Invalid amount");

        IERC20(token).safeTransfer(to, amount);
    }
}

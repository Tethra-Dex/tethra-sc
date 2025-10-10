// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TethraToken
 * @notice TETH - Tethra platform governance and utility token
 * @dev Total supply: 10,000,000 TETH
 *      Distribution:
 *      - Team: 20% (2M) - Immediate for testnet, vesting for mainnet
 *      - Staking Rewards: 50% (5M)
 *      - Liquidity Mining: 20% (2M)
 *      - Treasury: 10% (1M)
 */
contract TethraToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 10_000_000 * 10**18; // 10 million TETH
    
    // Distribution percentages
    uint256 public constant TEAM_ALLOCATION = 2_000_000 * 10**18; // 20%
    uint256 public constant STAKING_ALLOCATION = 5_000_000 * 10**18; // 50%
    uint256 public constant LIQUIDITY_MINING_ALLOCATION = 2_000_000 * 10**18; // 20%
    uint256 public constant TREASURY_ALLOCATION = 1_000_000 * 10**18; // 10%
    
    bool public isInitialized;
    
    event TokensDistributed(
        address indexed treasury,
        address indexed team,
        address indexed stakingVault,
        address liquidityMining
    );
    
    constructor() ERC20("Tethra Token", "TETH") Ownable(msg.sender) {
        // Token created but not minted yet
        // Will be minted during initialize() call
    }
    
    /**
     * @notice Initialize token distribution
     * @dev Can only be called once by owner
     * @param treasury Address for treasury allocation
     * @param team Address for team allocation
     * @param stakingVault Address for staking rewards
     * @param liquidityMining Address for liquidity mining rewards
     */
    function initialize(
        address treasury,
        address team,
        address stakingVault,
        address liquidityMining
    ) external onlyOwner {
        require(!isInitialized, "TethraToken: Already initialized");
        require(treasury != address(0), "TethraToken: Invalid treasury");
        require(team != address(0), "TethraToken: Invalid team");
        require(stakingVault != address(0), "TethraToken: Invalid staking vault");
        require(liquidityMining != address(0), "TethraToken: Invalid liquidity mining");
        
        isInitialized = true;
        
        // Mint tokens to distribution addresses
        _mint(treasury, TREASURY_ALLOCATION);
        _mint(team, TEAM_ALLOCATION);
        _mint(stakingVault, STAKING_ALLOCATION);
        _mint(liquidityMining, LIQUIDITY_MINING_ALLOCATION);
        
        // Verify total supply
        require(
            totalSupply() == TOTAL_SUPPLY,
            "TethraToken: Distribution mismatch"
        );
        
        emit TokensDistributed(treasury, team, stakingVault, liquidityMining);
    }
    
    /**
     * @notice Burn tokens
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
    
    /**
     * @notice Burn tokens from another address (requires allowance)
     * @param account Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }
}

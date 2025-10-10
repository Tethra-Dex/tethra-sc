// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testnet with faucet functionality
 * @dev ERC20 token with 6 decimals (matching real USDC)
 */
contract MockUSDC is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;
    uint256 public constant FAUCET_AMOUNT = 1000 * 10**DECIMALS; // 1000 USDC
    
    mapping(address => bool) public hasClaimed;
    
    event FaucetClaimed(address indexed user, uint256 amount);
    
    /**
     * @notice Constructor mints initial supply to deployer
     * @param initialSupply Initial supply in USDC (will be multiplied by 10**6)
     */
    constructor(uint256 initialSupply) ERC20("Mock USDC", "USDC") Ownable(msg.sender) {
        _mint(msg.sender, initialSupply * 10**DECIMALS);
    }
    
    /**
     * @notice Returns 6 decimals (matching real USDC)
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
    
    /**
     * @notice Faucet function - users can claim 1000 USDC once
     * @dev One claim per address
     */
    function faucet() external {
        require(!hasClaimed[msg.sender], "MockUSDC: Already claimed");
        
        hasClaimed[msg.sender] = true;
        _mint(msg.sender, FAUCET_AMOUNT);
        
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }
    
    /**
     * @notice Owner can mint additional USDC for testing
     * @param to Address to mint to
     * @param amount Amount to mint (in smallest unit)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    /**
     * @notice Owner can burn USDC
     * @param amount Amount to burn (in smallest unit)
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
    
    /**
     * @notice Reset faucet claim status (owner only, for testing)
     * @param user Address to reset
     */
    function resetFaucetClaim(address user) external onlyOwner {
        hasClaimed[user] = false;
    }
}

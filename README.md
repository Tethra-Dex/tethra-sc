# Tethra DEX Smart Contracts

![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)
![Foundry](https://img.shields.io/badge/Foundry-Latest-green)
![License](https://img.shields.io/badge/License-MIT-yellow)

Perpetual futures trading protocol on Base with **up to 100x leverage**, built with privileged smart wallets (Privy) and USDC gas payments (Account Abstraction).

## 🚀 Quick Start

```bash
# Install dependencies
forge install

# Compile contracts
forge build

# Run tests (when available)
forge test

# Deploy to testnet
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast
```

## 📁 Project Structure

```
tethra-sc/
├── src/
│   ├── tokens/
│   │   ├── MockUSDC.sol           # Mock USDC for testing
│   │   └── TethraToken.sol        # TETRA governance token
│   ├── risk/
│   │   └── RiskManager.sol        # Trade validation & liquidation
│   ├── trading/
│   │   ├── PositionManager.sol    # Position tracking & PnL
│   │   ├── MarketExecutor.sol     # Market orders
│   │   └── LimitExecutor.sol      # Limit orders & stop-loss
│   ├── treasury/
│   │   └── TreasuryManager.sol    # Fund management & fees
│   ├── paymaster/
│   │   └── USDCPaymaster.sol      # USDC gas payments (AA)
│   └── staking/
│       ├── TethraStaking.sol      # Stake TETRA for USDC
│       └── LiquidityMining.sol    # Provide USDC for TETRA
├── test/                           # Test files
├── script/                         # Deployment scripts
├── foundry.toml                    # Foundry configuration
├── CONTRACTS_DOCUMENTATION.md      # Full contract documentation
└── SETUP_GUIDE.md                  # Detailed setup guide
```

## 📦 Contracts Overview

### Core Trading (5 contracts)

1. **RiskManager** - Validates trades, manages leverage limits (100x BTC/ETH, 20x altcoins)
2. **PositionManager** - Tracks all positions, calculates PnL
3. **MarketExecutor** - Instant market orders with signed prices
4. **LimitExecutor** - Limit orders & stop-loss (keeper-executed)
5. **TreasuryManager** - Central treasury for all USDC flows

### Infrastructure (3 contracts)

6. **MockUSDC** - Test USDC with faucet (1,000 USDC per claim)
7. **TethraToken** - TETRA token (10M supply)
8. **USDCPaymaster** - Pay gas with USDC (Account Abstraction)

### Incentives (2 contracts)

9. **TethraStaking** - Stake TETRA → Earn USDC (30% of fees)
10. **LiquidityMining** - Provide USDC liquidity → Earn TETRA

## 🎯 Key Features

### For Traders
- ⚡ **Instant Execution** - Market orders filled immediately
- 📈 **High Leverage** - Up to 100x on BTC/ETH
- 🎯 **Advanced Orders** - Limit orders & stop-loss
- 💵 **USDC Gas Payments** - Pay fees in USDC, not ETH
- 🔐 **Embedded Wallets** - Privy smart wallets (email/social login)

### For Liquidity Providers
- 💎 **Earn TETRA** - 1 TETRA per block rewards
- 🏊 **Liquidity Pool** - Receive 50% of protocol fees
- 📊 **Dynamic APR** - Based on trading volume
- 🔒 **14-day Lock** - Optional early withdrawal (15% penalty)

### For TETRA Stakers
- 💰 **Earn USDC** - 30% of protocol fees
- ⏰ **7-day Lock** - Optional early unstake (10% penalty)
- 📈 **High APR** - Proportional to trading volume

## 🔐 Security Features

- ✅ **OpenZeppelin Contracts** - Battle-tested libraries
- ✅ **ReentrancyGuard** - All state-changing functions protected
- ✅ **Access Control** - Role-based permissions
- ✅ **SafeERC20** - Safe token transfers
- ✅ **Signed Prices** - ECDSA verification (5min validity)
- ✅ **No Upgrades** - Immutable contracts for security

## 💰 Fee Structure

| Action | Fee | Recipient |
|--------|-----|-----------|  
| Market Trade | 0.05% | Protocol |
| Limit Order Execution | 0.5 USDC | Keeper |
| Liquidation | 0.5% | Liquidator |
| Early Unstake | 10% | Treasury |
| Early LP Withdrawal | 15% | Treasury |

**Fee Distribution:**
- 50% → Liquidity Pool (backs trader profits)
- 30% → TETRA Stakers
- 20% → Protocol Treasury

## 🛠️ Development

### Build

```bash
forge clean && forge build
```

### Test

```bash
forge test
forge test --gas-report
forge test -vvv
```

### Deploy

```bash
# Deploy to Base Sepolia
forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --broadcast \
  --verify
```

## 📖 Documentation

- [Full Contract Documentation](./CONTRACTS_DOCUMENTATION.md) - Detailed API reference
- [Setup Guide](./SETUP_GUIDE.md) - Foundry setup & development
- [Architecture Document](../SC_ARCHITECTURE_UPDATED.md) - System architecture
- [Flow & Gas Document](../SC_FLOW_AND_GAS.md) - Detailed flows & gas analysis

## 📄 License

MIT License

---

**Built with ❤️ using Foundry**

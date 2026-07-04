[![npm](https://img.shields.io/npm/v/@dexe-network/dexe-protocol.svg)](https://www.npmjs.com/package/@dexe-network/dexe-protocol)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI](https://github.com/PandaKitten96/DeXe-Protocol/actions/workflows/test-smart-contracts.yml/badge.svg)](https://github.com/PandaKitten96/DeXe-Protocol/actions/workflows/test-smart-contracts.yml)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/PandaKitten96?label=Sponsors&logo=githubsponsors)](https://github.com/sponsors/PandaKitten96)

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/.github/dexe_github_b.svg">
  <source media="(prefers-color-scheme: light)" srcset="/.github/dexe_github_w.svg">
  <img alt="DeXe Protocol" src="/.github/dexe_github_w.svg">
</picture>
</div>

# DeXe Protocol

The DeXe Protocol is an open-source library of smart contracts for building and governing effective DAOs. It’s a comprehensive and flexible infrastructure that allows building custom DAOs for any specific need, from straightforward to complex organizational structures.

## 💖 Support This Project

DeXe Protocol is free, open-source software maintained by the community. If you or your organization rely on these smart contracts, please consider supporting continued development:

**[❤️ Become a GitHub Sponsor](https://github.com/sponsors/PandaKitten96)**

Your sponsorship helps fund:
- Ongoing security audits
- New features and improvements
- Bug fixes and maintenance
- Community support

## Table of Contents

- [Features](#features)
- [Contract Architecture](#contract-architecture)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Protocol Deployments](#protocol-deployments)
- [Audits and Security](#audits-and-security)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Flexible DAO creation** — deploy DAOs ranging from simple token-voting setups to complex multi-layer governance structures
- **On-chain governance** — create, vote on, and execute proposals entirely on-chain
- **NFT voting power** — boost voting weight using ERC-721 NFT multipliers
- **Expert NFTs** — issue soulbound ERC-721 tokens to recognize community experts, granting special governance privileges
- **Validator layer** — optional secondary committee that can veto or approve proposals before execution
- **Delegated voting** — token holders can delegate their voting power to other addresses
- **Upgradeable contracts** — all core contracts use the transparent proxy pattern (OpenZeppelin)
- **SphereX integration** — runtime on-chain security engine to protect against exploits

## Contract Architecture

```
contracts/
├── core/               # Registry, price feed, and global configuration
│   ├── ContractsRegistry.sol
│   ├── CoreProperties.sol
│   ├── PriceFeed.sol
│   └── TokenAllocator.sol
├── factory/            # Pool (DAO) creation and registry
│   ├── PoolFactory.sol
│   └── PoolRegistry.sol
├── gov/                # Governance logic
│   ├── GovPool.sol         # Main DAO entry point
│   ├── proposals/          # Proposal execution helpers
│   ├── settings/           # Configurable voting parameters
│   ├── user-keeper/        # Token and NFT custody for voting
│   ├── validators/         # Optional validator committee
│   ├── voting/             # Voting mechanisms
│   └── ERC20/ERC721/       # Governance tokens and expert NFTs
├── user/               # User registry and KYC/SBT
│   └── UserRegistry.sol
├── libs/               # Shared Solidity libraries
├── interfaces/         # All contract interfaces
└── proxy/              # Upgradeable proxy contracts
```

**Key relationships:**
1. `PoolFactory` deploys a new `GovPool` and its satellite contracts (`GovSettings`, `GovUserKeeper`, `GovValidators`) in a single transaction.
2. `GovPool` coordinates proposal creation, voting, delegation, and execution.
3. `GovUserKeeper` holds deposited ERC-20 tokens and ERC-721 NFTs used as voting power.
4. `ContractsRegistry` acts as the single source of truth for all protocol-level contract addresses.

## Getting Started

### Prerequisites

- [Node.js](https://nodejs.org/) v20.x or later
- [npm](https://www.npmjs.com/) v8 or later

### Installation

```bash
# Clone the repository
git clone https://github.com/PandaKitten96/DeXe-Protocol.git
cd DeXe-Protocol

# Install dependencies
npm install
```

### Configuration

Copy the example environment file and fill in the required values:

```bash
cp .env.example .env
```

| Variable           | Description                                      |
| :----------------- | :----------------------------------------------- |
| `PRIVATE_KEY`      | Deployer wallet private key                      |
| `AUXILIARY_KEY`    | Secondary wallet private key                     |
| `INFURA_KEY`       | Infura project ID (for forking / public RPCs)    |
| `ETHERSCAN_KEY`    | Etherscan API key (for contract verification)    |
| `BSCSCAN_KEY`      | BscScan API key                                  |
| `POLYGONSCAN_KEY`  | Polygonscan API key                              |
| `OPTIMISM_KEY`     | Optimism Etherscan API key                       |
| `BASE_KEY`         | BaseScan API key                                 |
| `COINMARKETCAP_KEY`| CoinMarketCap API key (for gas reporter)         |
| `ENVIRONMENT`      | Deployment target (`PROD`, `STAGE`, `DEV`, etc.) |

### Using as an npm Package

DeXe Protocol contracts are published to npm and can be imported directly into your Solidity project:

```bash
npm install @dexe-network/dexe-protocol
```

```solidity
import "@dexe-network/dexe-protocol/contracts/interfaces/gov/IGovPool.sol";
```

## Usage

### Compile

```bash
npm run compile
```

### Test

```bash
npm run test
```

### Coverage

```bash
npm run coverage
```

### Lint

```bash
npm run lint-fix
```

### Run a Local Node

```bash
npm run private-network
```

### Deploy

| Command                      | Network                  |
| :--------------------------- | :----------------------- |
| `npm run deploy-dev`         | Local Hardhat node       |
| `npm run deploy-bsc`         | BNB Chain (mainnet)      |
| `npm run deploy-chapel`      | BNB Chain Testnet        |
| `npm run deploy-eth`         | Ethereum mainnet         |
| `npm run deploy-sepolia`     | Ethereum Sepolia testnet |
| `npm run deploy-amoy`        | Polygon Amoy testnet     |
| `npm run deploy-sepolia-optimism` | Optimism Sepolia    |
| `npm run deploy-sepolia-base`| Base Sepolia             |

All mainnet / testnet deploy commands automatically verify contracts on the respective block explorer.

### Generate TypeChain Bindings

```bash
npm run generate-types
```

## Protocol Deployments

### Production (BNB Chain)

| Name                | Address                                    |
| :------------------ | :----------------------------------------- |
| DeXe DAO            | 0xB562127efDC97B417B3116efF2C23A29857C0F0B |
| DeXe DAO Token      | 0x6E88056E8376AE7709496BA64D37FA2F8015CE3E |
| DeXe NFT Multiplier | 0x67fAC5aEE5b31e85dE5458676080326a1C034A85 |
| ContractsRegistry   | 0x46B46629B674b4C0b48B111DEeB0eAfd9F84A1c0 |
| UserRegistry        | 0x427a1214f12117b1AD48C817c203c5CF3Eb7E7C4 |
| CoreProperties      | 0xaB9d2a2347D5fF5B760C0226C52d5C673b8D9e44 |
| PriceFeed           | 0xc7730074736c10ed0d3F928A10Ee4162DA9a7983 |
| ERC721Expert        | 0x892B3292cF80CB298b7fA20D04EF4732640db404 |
| PoolFactory         | 0x85f86ef7E72e86BdEAb5F65e2B76A2c551f22109 |
| PoolRegistry        | 0xFEB26AAB75638440B3CEFe8B10de6118972f9C6B |
| SphereXEngine       | 0x41260f637a993ce714Ece1ee9875F489e483e9b3 |
| PoolSphereXEngine   | 0x4fa2092E32934Dd3823E58C79ceD0e410a5B0D4b |

### Stage (BNB Chain Testnet)

| Name                | Address                                    |
| :------------------ | :----------------------------------------- |
| DeXe DAO            | 0xB562127efDC97B417B3116efF2C23A29857C0F0B |
| DeXe DAO Token      | 0xf42F27612af98F40865Dc3CB8531d3aa4C44A8E5 |
| DeXe NFT Multiplier | 0x835d3B1781eC7411cf3c1C81956169c2c8B2497C |
| ContractsRegistry   | 0x46B46629B674b4C0b48B111DEeB0eAfd9F84A1c0 |
| UserRegistry        | 0x427a1214f12117b1AD48C817c203c5CF3Eb7E7C4 |
| CoreProperties      | 0xaB9d2a2347D5fF5B760C0226C52d5C673b8D9e44 |
| PriceFeed           | 0xc7730074736c10ed0d3F928A10Ee4162DA9a7983 |
| ERC721Expert        | 0x892B3292cF80CB298b7fA20D04EF4732640db404 |
| PoolFactory         | 0x85f86ef7E72e86BdEAb5F65e2B76A2c551f22109 |
| PoolRegistry        | 0xFEB26AAB75638440B3CEFe8B10de6118972f9C6B |
| SphereXEngine       | 0x41260f637a993ce714Ece1ee9875F489e483e9b3 |
| PoolSphereXEngine   | 0x4fa2092E32934Dd3823E58C79ceD0e410a5B0D4b |

## Audits and Security

DeXe Protocol smart contracts have been audited by several external auditors, and the full reports are available on [this repository](https://github.com/dexe-network/DeXe-Protocol/tree/master/audits) or via the links provided below.

If you discover a security vulnerability, **please do not open a public issue**. Report it privately via [GitHub Security Advisories](https://github.com/PandaKitten96/DeXe-Protocol/security/advisories/new) or contact the maintainers directly.

### DeXe Protocol smart contracts audit reports

#### [Certik](https://github.com/dexe-network/DeXe-Protocol/blob/master/audits/certik-2023-05-04.pdf)
#### [Cyfrin](https://github.com/dexe-network/DeXe-Protocol/blob/master/audits/cyfrin-2023-11-10.pdf)
#### [Hacken](https://github.com/dexe-network/DeXe-Protocol/blob/master/audits/hacken-2023-05-22.pdf)
#### [Ambisafe](https://github.com/dexe-network/DeXe-Protocol/blob/master/audits/ambisafe-2023-07-18.pdf)
#### [Ambisafe #2](https://github.com/dexe-network/DeXe-Protocol/blob/master/audits/ambisafe-2023-11-10.pdf)

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines on how to report bugs, suggest features, and submit pull requests.

## License

DeXe Protocol is released under the [MIT License](https://opensource.org/licenses/MIT).

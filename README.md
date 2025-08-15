# Uniswap V4 Volatility Shield Hook Demo

This repository contains a **demo implementation** of a custom Uniswap V4 hook (`VolatilityShieldHook`) that dynamically adjusts swap fees to protect against large price swings (MEV protection). It includes deployment and demo scripts using **Foundry**.

## Prerequisites

* [Foundry](https://book.getfoundry.sh/getting-started/installation)
* Node.js >= 18 (if using `npm` for other dependencies)
* Git

## Project Structure

```
.
├── src/
│   └── hooks/
│       └── VolatilityShieldHook.sol
├── script/
│   ├── DeployHook.s.sol
│   ├── DemoSwap.s.sol
│   └── DeployedAddresses.sol
├── foundry.toml
├── remappings.txt
├── README.md
└── foundry.lock
```

* `src/hooks/`: contains the hook implementation.
* `script/`: deployment and demo scripts.
* `DeployedAddresses.sol`: holds the deployed hook address and pool key placeholders.
* `foundry.toml`, `remappings.txt`, `foundry.lock`: Foundry configuration and dependency info.

## Installation

1. Clone the repo:

```bash
git clone <your-repo-url>
cd uniswap-v4-advanced-hook
```

2. Install dependencies:

```bash
forge install foundry-rs/forge-std
forge install uniswap/v4-core
forge install openzeppelin/openzeppelin-contracts
```

3.	Check or update remappings.txt to include:
   
```bash
@uniswap/v4-core/=lib/v4-core/src/
@openzeppelin/=lib/openzeppelin-contracts/
forge-std/=lib/forge-std/src/
```
   
4. Build contracts:

```bash
forge clean
forge build
```

## Running Scripts

### Deploy Hook

```bash
forge script script/DeployHook.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <your-private-key> \
  --broadcast
```

* Deploys the `VolatilityShieldHook` to your local Hardhat/Anvil node.
* Saves transaction info in `broadcast/` and the deployed address in `script/DeployedAddresses.sol`.

### Run Demo Swap

```bash
./run_demo.sh
```

* Uses the deployed hook address and simulates swaps.
* Logs outputs like `seedObservation` and fee application for calm/volatile swaps.

**Expected Output:**

```
Hook deployed at: <hook-address>
seedObservation called.
Calm swap simulation succeeded. Fee applied: <fee>
Volatile swap simulation blocked by hook: <reason>
```

> Note: No real tokens or pools are required; this runs locally as a demo.

## Notes

* All addresses and pools are placeholders for demonstration.
* For real deployment, update `DeployedAddresses.sol` with real token addresses and pool key.
* Minimal setup required: just Foundry and a local node (Anvil/Hardhat).

## License

MIT

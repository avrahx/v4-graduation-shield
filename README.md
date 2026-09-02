# Uniswap v4 Graduation Shield Hook (`v4-graduation-shield`)

[![Foundry](https://img.shields.io/badge/Foundry-passing-brightgreen)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://soliditylang.org/)
[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4--Core-pink)](https://github.com/uniswap/v4-core)

A production-ready Uniswap v4 Hook that prevents post-migration liquidity depletion on retail launchpads (e.g., Robinhood Chain, Pons Family, Pump-style bonding curves) through asymmetric directional fee discrimination and mathematical time-decay defense.

---

## The Problem: The "Graduation Cliff"

When a token completes its bonding-curve phase and migrates into an open Automated Market Maker (AMM), it enters an environment with static fee tiers. Early discount buyers and front-running snipers typically extract liquidity within the first few blocks:

```text
[Bonding Curve Phase] --------> [Graduation Event] --------> [Open AMM Phase]

Supply-dependent pricing      * 100% Reserves seeded       * Static 0.30% pool fee
Zero sandwich MEV               into open AMM pool         * Sniper bots dump at 10x-50x
Locked reserves                                            * Buy-side liquidity collapses
                                                           +--> "THE GRADUATION CLIFF"
```

Because baseline AMM pools apply uniform fees across all trade directions and timestamps, early extractors can dump millions of tokens with virtually zero penalty, draining up to 90% of newly seeded ETH/USDC reserves.

---

## The Solution: Directional Decay Defense

`GraduationShieldHook` intercepts swaps inside Uniswap v4's `beforeSwap` lifecycle:

1. **Trade Direction Discrimination:** 
   * **Inflow (Buys):** Swappers purchasing the newly graduated token receive the standard baseline fee (0.30%) to promote organic order flow.
   * **Outflow (Sells):** Early dumpers pay a steep initial penalty fee (15.00%) that linearly decays to baseline over a stabilization window ($T = 7,200\text{ s}$).

2. **Mathematical Formulation:**

* If $(t - t_{\text{grad}}) \ge T_{\text{window}}$:
  $$\text{Fee}_{\text{sell}}(t) = \text{BASE\_FEE}$$

* If $(t - t_{\text{grad}}) < T_{\text{window}}$:
  $$\text{Fee}_{\text{sell}}(t) = \text{MAX\_FEE} - \left\lfloor \frac{(t - t_{\text{grad}}) \times (\text{MAX\_FEE} - \text{BASE\_FEE})}{T_{\text{window}}} \right\rfloor$$

Where:
* $\text{MAX\_FEE} = 150,000\text{ pips } (15.00\%)$
* $\text{BASE\_FEE} = 3,000\text{ pips } (0.30\%)$
* $T_{\text{window}} = 7,200\text{ seconds } (2\text{ Hours})$

---

## Architecture & Lifecycle Flow

```text
                 +----------------------------------------------+
                 |          PoolManager.sol (Uniswap v4)        |
                 +----------------------+-----------------------+
                                        |
                                        v
                       1. beforeSwap Hook Callback
                 +----------------------------------------------+
                 |          GraduationShieldHook.sol            |
                 |                                              |
                 | 1. Identify trade direction (zeroForOne)     |
                 | 2. Compute elapsed delta_t = now - t_grad    |
                 | 3. If Buy: return BASE_FEE (0.30%)           |
                 | 4. If Sell: compute decay fee (15% -> 0.3%)  |
                 | 5. Return fee | LPFeeLibrary.OVERRIDE_FLAG   |
                 +----------------------------------------------+
```

---

## Contract Addresses & Bitmask Specification

Uniswap v4 enforces hook permissions via the leading bits of the deployed hook address. `GraduationShieldHook` requires:
* `Hooks.BEFORE_INITIALIZE_FLAG` (`1 << 13`)
* `Hooks.BEFORE_SWAP_FLAG` (`1 << 7`)

The project includes an optimized `HookMiner.sol` library that brute-forces `CREATE2` salts until an address matches the target flag bitmask `(1 << 13) | (1 << 7)`.

---

## Getting Started

### Prerequisites
* [Foundry](https://getfoundry.sh/)

### Installation
```bash
git clone https://github.com/avrahx/v4-graduation-shield.git
cd v4-graduation-shield
forge install
```

### Build
```bash
forge build
```

### Run Tests
```bash
forge test -vvv
```

### Deploy
```bash
forge script script/DeployShieldHook.s.sol
```

---

## Directory Structure

```text
├── src/
│   ├── GraduationShieldHook.sol   # Dynamic exit fee calculation and LP fee override
│   └── base/
│       └── BaseHook.sol           # Base contract with internal hook dispatching
├── script/
│   ├── DeployShieldHook.s.sol     # CREATE2 deployment script
│   └── MineHookSalt.s.sol         # CREATE2 address bitmask salt miner (0x2080)
├── test/
│   ├── GraduationShieldHook.t.sol # Unit and integration tests with Uniswap v4 test harness
│   └── utils/
│       └── HookMiner.sol          # Reusable CREATE2 hook salt mining library
├── foundry.toml                   # Compiler settings: solc 0.8.26, cancun EVM, via_ir enabled
└── remappings.txt                 # Canonical dependencies: v4-core, v4-periphery, openzeppelin
```

---

## License

This project is licensed under the [MIT License](LICENSE).

# GraduationShieldHook 🛡️
> **Dynamic Liquidity Defense Hook for Uniswap v4**

A production-grade Uniswap v4 Hook designed to eliminate the **"Graduation Cliff"** — the sharp liquidity drain and price collapse that occurs when bonding-curve launchpad tokens (e.g. pump.fun style) transition into standard AMM pools.

---

## 📌 Problem & Context: The Graduation Cliff

When bonding-curve launchpad tokens reach their funding goal, their accumulated reserves graduate into a Uniswap v4 pool. Early discount buyers who accumulated large stakes on the bonding curve often immediately dump their tokens into the AMM pool ("the cliff"), extracting reserve assets (ETH/USDC) and leaving late adopters and liquidity providers with heavy losses.

**GraduationShieldHook** protects the pool and its liquidity providers by implementing:
1. **Dynamic Time-Decay Exit Fees on Sells**: Starts with a punitive defense fee (15%) decaying linearly to standard base fee (0.3%) over a configurable duration (e.g. 7 days).
2. **Standard 0.3% Fees on Buys**: Buyers are never penalized and trade with standard pool fees.
3. **Price Floor Defense via `PoolManager.donate()`**: Rather than burning or routing excess exit fees to a central treasury, the hook intercepts the excess penalty via `BeforeSwapDelta` and immediately donates it to active in-range LPs via `poolManager.donate()`. This increases `feeGrowthGlobal` and reinforces the price floor.
4. **Anti-Fee Evasion**: Exact-output sells are rejected during the active cliff period to prevent MEV searchers and dumpers from bypassing the input fee calculation.
5. **CREATE2 Address Flag Mining**: Deterministic salt-mining script to deploy the hook to a verified Uniswap v4 address bitmask.

---

## ⚙️ Architecture & Mechanism Flow

```mermaid
flowchart TD
    Swapper([Trader / Seller]) --> HookCheck{Is Swap a Sell of Graduated Token?}
    HookCheck -->|No (Buy / Quote Swap)| BuyRoute[Standard 0.3% Base LP Fee]
    HookCheck -->|Yes (Sell / Dump)| CalcDecay[Calculate Linear Time-Decay Fee]
    CalcDecay --> FeeSplit[Split: 0.3% Base LP Fee + Excess Defense Fee]
    FeeSplit --> HookDelta[Hook intercepts Excess Fee via beforeSwap delta]
    HookDelta --> SwapExec[PoolManager executes Swap on net amount]
    SwapExec --> AfterSwapHook[afterSwap: Hook triggers PoolManager.donate]
    AfterSwapHook --> LPs([In-Range LPs receive 100% of Defense Fee Windfall])
```

---

## 📐 Mathematical Specification

### Linear Exit Fee Decay
Let:
- $F_{\text{initial}} = 150,000$ (15.00% in hundredths of a bip)
- $F_{\text{base}} = 3,000$ (0.30% in hundredths of a bip)
- $T_{\text{decay}} = \text{decayDuration}$ (e.g. 7 days)
- $t_{\text{grad}} = \text{graduationTimestamp}$
- $\Delta t = \min(\text{block.timestamp} - t_{\text{grad}}, T_{\text{decay}})$

The dynamic sell fee $F_{\text{sell}}(t)$ is:
$$F_{\text{excess}}(\Delta t) = (F_{\text{initial}} - F_{\text{base}}) \times \frac{T_{\text{decay}} - \Delta t}{T_{\text{decay}}}$$

$$F_{\text{sell}}(t) = F_{\text{base}} + F_{\text{excess}}(\Delta t)$$

### Trajectory Milestones

| Elapsed Time | % of Duration | Sell Fee (%) | Excess Fee Donated (%) | Buy Fee (%) |
|---|---|---|---|---|
| $t = 0$ (Graduation) | 0% | **15.000%** | **14.700%** | 0.300% |
| $t = 1.75$ days | 25% | **11.325%** | **11.025%** | 0.300% |
| $t = 3.50$ days | 50% | **7.650%** | **7.350%** | 0.300% |
| $t = 5.25$ days | 75% | **3.975%** | **3.675%** | 0.300% |
| $t \ge 7.00$ days | 100% | **0.300%** | **0.000%** | 0.300% |

---

## 🔑 Hook Address Bitmask & Permissions

Uniswap v4 verifies that the least significant 14 bits of a hook address strictly match its declared permissions.

`GraduationShieldHook` requires:
- `AFTER_INITIALIZE_FLAG` (`1 << 12` = `0x1000`): Registers graduation timestamp and pool parameters.
- `BEFORE_SWAP_FLAG` (`1 << 7` = `0x0080`): Computes dynamic sell fee and validates trade direction.
- `AFTER_SWAP_FLAG` (`1 << 6` = `0x0040`): Executes LP fee donation via `PoolManager.donate()`.
- `BEFORE_SWAP_RETURNS_DELTA_FLAG` (`1 << 3` = `0x0008`): Intercepts the excess fee from the swapper's specified input amount.

**Required Bitmask**: `0x1000 | 0x0080 | 0x0040 | 0x0008 = 0x10C8`.

---

## 🧪 Test Suite & Verification

The test suite covers 14 comprehensive unit, integration, and invariant tests:

```shell
$ forge test -vvv
```

### Test Results:
```text
Ran 14 tests for test/GraduationShieldHook.t.sol:GraduationShieldHookTest
[PASS] test_BuySwapStandardFee() (gas: 143052)
[PASS] test_ExactOutputSellAllowedPostDecay() (gas: 147504)
[PASS] test_ExactOutputSellRevertsDuringCliff() (gas: 63988)
[PASS] test_InitialPoolConfiguration() (gas: 15843)
[PASS] test_Permissions() (gas: 10162)
[PASS] test_PriceFloorDefenseFeeGrowth() (gas: 170269)
[PASS] test_SellFee_At_FullDuration_T1() (gas: 20677)
[PASS] test_SellFee_At_Graduation_T0() (gas: 17733)
[PASS] test_SellFee_At_HalfDuration_T1_2() (gas: 21632)
[PASS] test_SellFee_At_QuarterDuration_T1_4() (gas: 21412)
[PASS] test_SellFee_At_ThreeQuartersDuration_T3_4() (gas: 21082)
[PASS] test_SellFee_Past_DecayWindow() (gas: 21007)
[PASS] test_SellImmediateCliffMaxFee() (gas: 172775)
[PASS] test_SellPostDecayDuration() (gas: 152857)
Suite result: ok. 14 passed; 0 failed; 0 skipped;
```

---

## ⛏️ Mining CREATE2 Salt for Deployment

To deploy `GraduationShieldHook` to a valid address matching the `0x10C8` bitmask, run the included Foundry script:

```shell
$ forge script script/MineHookSalt.s.sol
```

Example Output:
```text
== Logs ==
  Mining salt for deployer: 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38
  Required hook flags bitmask: 0x10C8
  Success! Found valid salt at iteration: 2406
  Salt: 0x0000000000000000000000000000000000000000000000000000000000000966
  Predicted Hook Address: 0x88a3Aa9ac53Ad33fcE2aFc9160BE2f0443EB90c8
```

Notice the lowest 16 bits: `0x90C8 & 0x3FFF = 0x10C8`.

---

## 📁 Repository Structure

```text
├── src/
│   ├── GraduationShieldHook.sol   # Core hook contract with dynamic decay & donation
│   └── base/
│       └── BaseHook.sol           # Abstract base contract for Uniswap v4 hook permissions
├── script/
│   └── MineHookSalt.s.sol         # CREATE2 address mining script
├── test/
│   └── GraduationShieldHook.t.sol # 14 comprehensive test cases with Uniswap v4 test harness
├── foundry.toml                   # Foundry configuration (cancun, via_ir, solc 0.8.26)
└── remappings.txt                 # Dependencies: v4-core, v4-periphery, openzeppelin
```

---

## 📜 License
MIT

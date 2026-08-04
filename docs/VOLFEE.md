# VolFee — realized-volatility dynamic LP fee

VolFee is a single Uniswap v4 hook on one canonical **dynamic-fee** pool. It does two independent things.

## 1. Realized-volatility dynamic LP fee (the novel value → LPs)

The pool is initialized with the dynamic-fee flag. The hook computes and applies a **per-swap LP fee override** from the pool's own realized volatility, measured on-chain with no external price source, no keeper and no governance.

- **Metric.** `ewmaVol` = an exponentially-weighted moving average of the absolute per-swap tick delta `|tickNow − tickPrev|`, sampled once per swap from the pool's post-swap tick (`poolManager.getSlot0`). Smoothing uses an immutable `ALPHA_BPS`.
- **Curve.** `lpFee = clamp(baseFee + K_NUM·ewmaVol/K_DEN, MIN_LP_FEE, MAX_LP_FEE)` — monotonic non-decreasing in volatility, hard-bounded, with overflow guards that clamp to `MAX_LP_FEE` (all in `src/lib/VolMath.sol`, pure + fuzz-tested).
- **Application.** `afterInitialize` sets the immutable base fee once via `updateDynamicLPFee`; every `beforeSwap` returns `lpFee | OVERRIDE_FEE_FLAG` for that swap; every `afterSwap` recomputes `ewmaVol`/`lastTick` from the executed tick move.

### Manipulation resistance (read-before / update-after)

The fee charged on swap *N* is computed in `beforeSwap` from the volatility state accumulated by swaps **before** *N*; the state is updated only afterwards in `afterSwap`. Therefore a trader **cannot lower their own swap's fee** with their own trade. Manufacturing volatility to raise other traders' fees costs the mandatory volume fee on every swap and moves the price against the manipulator, and the fee is hard-bounded to `[MIN_LP_FEE, MAX_LP_FEE]` (`MAX_LP_FEE < 100%`, so exact-output stays supported).

## 2. Mandatory Programmable volume fee (platform + project)

On the same pool the hook enforces the mandatory `programmable-volume-fee-v1` policy, non-bypassably, via quadrant-dependent before/after return deltas on the quote (WETH) side of every swap:

- `effective = max(selected, 1000)` hundredths-of-a-bip; `platform = 1000` (10 bps) accrues to the immutable owner `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c` as an owner-claimable liability (`programmableFeeOwed`); `project = effective − 1000` accrues to the immutable `PROJECT` beneficiary as a project-claimable liability (`projectFeeOwed`).
- Both liabilities are held as the hook's ERC-6909 quote claims in PoolManager. **Solvency by construction:** hook 6909 quote balance == `programmableFeeOwed + projectFeeOwed` (there is no reserve and no subsidy). Each liability leaves only through its authenticated claim (`claimProgrammableFee` / `claimProjectFee`), zero-before-pay (CEI), to a per-claim destination.

The dynamic LP fee (to LPs) and the mandatory fee (hook-owned) are separate value flows on the same swap; the LP fee is `lpFeeExcluded` from the mandatory-fee split.

## What VolFee is NOT

No oracle / external price source, no keeper, no admin, no upgrade path, no reserve, no custody of pool liquidity, no `hookData`, no cross-chain, no token transfer tax. The hook never initiates a swap on its own pool.

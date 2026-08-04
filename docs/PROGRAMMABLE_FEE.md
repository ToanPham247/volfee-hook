# Mandatory Programmable volume fee — VolFee compliance

VolFee integrates the mandatory `programmable-volume-fee-v1` policy into its single custom hook (`src/VolFeeHook.sol`). This is independent of, and separate from, the dynamic LP fee (see `VOLFEE.md`).

## Rates (hundredths-of-a-bip; 1000 = 10 bps)

- `selected = feeTotalBps * 100` (immutable constructor arg).
- `effective = max(selected, 1000)`.
- `platform = 1000` (exactly 10 bps) — the fixed platform slice.
- `project = effective − 1000`.

The split is **non-additive**: `platform + project ≡ total`; a 3% total is never turned into 3.1%. `project == 0` exactly when `effective == 1000`. `lpFeeExcluded: true` — the pool LP fee is separate and belongs to LPs.

## Basis & rounding

Fees accrue on the **executed** gross quote-side (WETH) swap volume — the actual post-partial-fill amount, read from `|amountSpecified|` (before-quadrants) or the swap `BalanceDelta` (after-quadrants). Amounts **ceil** (protocol favor), so `platform + project` always equals the taken total and the hook is never under-collected.

## Quadrant-dependent collection

Collect BEFORE (a positive `beforeSwapReturnDelta` on the specified currency) iff the quote is the swap's specified currency, else AFTER (a positive `afterSwap` return delta on the unspecified currency):

| quote asset | 0→1 exactIn | 0→1 exactOut | 1→0 exactIn | 1→0 exactOut |
| --- | --- | --- | --- | --- |
| currency0 (WETH) | before | after | after | before |

The total charge is minted as the hook's ERC-6909 quote claims (`take(..., claims=true)`), split into `programmableFeeOwed[poolId][quote]` (owner) and `projectFeeOwed[poolId][quote]` (project).

## Owner & claim authority

- Immutable owner `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c`; owner-only claim, anytime, to an owner-selected destination per claim; no stored mutable recipient; no cross-pool netting. Builder / project / administrators cannot claim, mutate, rescue or redirect the platform liability.
- The project slice accrues to the immutable `PROJECT` beneficiary, claimable only by `PROJECT` via `claimProjectFee` (mirrors the platform claim). Both claims are zero-before-pay (CEI); the shared `unlockCallback` burns the hook's quote claims and pays the underlying.

## Non-substitutability & self-call

The dynamic LP fee, and any pool LP fee, cannot satisfy or bypass this mandatory charge. `selfCallPolicy = same-pool-swap-forbidden`: the hook contains no `poolManager.swap` call; all entry points are `onlyPoolManager`.

Evidence: `test/ProgrammableFee.t.sol` (four-quadrant fee, non-additive split, executed basis, owner + project claims, solvency, events) and the invariant / fork suites.

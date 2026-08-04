# Slither triage — VolFee (0 true-positive)

Slither 0.11.6 on `src/` (node_modules + test filtered). 17 findings, all false-positive / style.

| Impact | Detector | Disposition |
| --- | --- | --- |
| Medium (3) | `unused-return` | Intentional: `poolManager.unlock()` returns empty bytes (the callback does the work); `getSlot0` partial destructure keeps only the tick. No value ignored. |
| Low (5) | `reentrancy-benign` / `reentrancy-events` | Calls are to the trusted PoolManager inside its own lock (`take`/`settle`/`updateDynamicLPFee`); claims are zero-before-pay (CEI); a nested `unlock` reverts. Slither itself labels them benign. |
| Informational (9) | `naming-convention` | SCREAMING_CASE immutables (OWNER, PROJECT, MIN_LP_FEE, …) and `_`-prefixed params are an intentional convention. |

Raw findings: `evidence/slither-hook-findings.json`.

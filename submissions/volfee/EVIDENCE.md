# Evidence index — VolFee

| Gate | Evidence |
| --- | --- |
| format-build-size-warnings | `evidence/forge-build.txt`, `.gas-snapshot` |
| unit-integration-fuzz-invariant-tests | `evidence/forge-test-local.txt` (58 local tests) |
| static-analysis | `evidence/slither-hook-triage.md`, `evidence/slither-hook-findings.json` |
| mainnet-fork-pinned-and-head-smoke | `evidence/forge-test-fork.txt`, `submissions/volfee/deployment-evidence.json` |
| fee-four-quadrant / programmable-fee-formula-and-claim | `evidence/forge-test-local.txt` (`test/ProgrammableFee.t.sol`) |
| dynamic-fee-properties / dynamic-fee-manipulation-tests | `evidence/forge-test-local.txt` (`test/VolAdaptiveFee.t.sol`) |
| erc6909-liability-solvency / reserve-reconstruction-and-solvency | `evidence/forge-test-local.txt` (`test/invariant/VolFeeInvariant.t.sol`) |
| package-dependency-lock-and-closure-verification | `submissions/volfee/dependency-lock.json`, `compatibility.lock.json` |

Compiler: solc 0.8.26 / cancun / optimizer runs=200 / bytecode_hash=none (see `compatibility.lock.json`, `out/build-info/`). PoolManager runtime identity: `submissions/volfee/deployment-evidence.json`.

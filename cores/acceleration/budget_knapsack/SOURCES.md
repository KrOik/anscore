# Provenance and reuse decision

Baseline: `99b5c8c1b3530775bb9dca0e5b4d1df07a014f68`.
New RTL, example, testbench, runner and prose are independent ANSCORE
contributions under the repository root Apache-2.0 LICENSE and NOTICE.
The package has no third-party source, executable or runtime dependency.

Before implementation, semantic searches across acceleration, storage and
common-scaffold RTL/README assets checked knapsack, subset-sum and budgeted
resource selection. No existing package provided exact 0/1 optimization with
item replay and value/cost/bitmap tie order. Existing graph and scheduling
assets do not implement this capability. No mature asset was modified.

## Actual read-only upstream preflight

Primary reference: [Google OR-Tools](https://github.com/google/or-tools),
tag v9.11 resolved to commit
`ed94162b910fa58896db99191378d3b71a5313af`.
Before writing RTL, the actual fixed-commit files were retrieved and read:

| File | Bytes | SHA256 |
|---|---:|---|
| [LICENSE](https://github.com/google/or-tools/blob/ed94162b910fa58896db99191378d3b71a5313af/LICENSE) | 11,358 | cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 |
| [ortools/algorithms/knapsack_solver.cc](https://github.com/google/or-tools/blob/ed94162b910fa58896db99191378d3b71a5313af/ortools/algorithms/knapsack_solver.cc) | 60,560 | 0af52126979ee5f7d4b09eedd8baaa82d6dff669c1067d8aaf5e0bfe6393685e |

The full Apache-2.0 license and relevant
`KnapsackDynamicProgrammingSolver::Solve` implementation were inspected.
The source header identifies Copyright 2010-2024 Google LLC. This was a
read-only algorithm/architecture comparison, without executing upstream
scripts, builds or binaries. The web search endpoint failed with HTTP 500;
fixed GitHub API/raw requests supplied the primary source and license with
15-second request limits.

The software solver and reconstruction are not a synthesizable memory/control
implementation and do not specify this package's minimum-cost/minimum-mask,
zero-budget, framing, reset or backpressure contract. No upstream code or
prose was copied, translated, adapted or distributed. There is no API or
bitwise compatibility claim and no imported license obligation. The original
RTL uses a bounded synchronous DP memory and serialized update/replay states.

## Offline closure and evidence boundaries

`files.f` contains only `rtl/budget_knapsack.sv`.
`examples/select16.sv` depends only on that core. The test runner uses Python
standard-library modules plus an already installed Icarus/vvp. No download,
generated coefficient table, external memory model or untracked sibling RTL
is needed. The repository root LICENSE and NOTICE are part of the cumulative
export closure.

The recorded tests apply to the source hashes in `verification.json`; the
cumulative snapshot binds every package file from committed Git blob bytes.
No physical implementation or board evidence is claimed. The qualitative
resource estimate is a structural calculation, not a synthesis result.

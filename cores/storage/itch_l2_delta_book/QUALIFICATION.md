# B37 finite qualification

The only authorized first preparation/execution passed11/11 children and four
simulations. No failure, timeout, retry or post-run executable edit occurred.
Receipt: `reports/20261106T042737498295Z/results.json`, SHA256
`9494412f358f3c0c6bac977fa759138ae414abfa181282ab093b82f692f5af5f`.
Baseline: `46630205095a13ab95e1b5bebea0094c2a390390`.

The source-only Worker C review and root plan review closed without blockers
before the run. Approved FINITE_PLAN SHA256 is
`ce56def12b472022a0344350384901c6209cd5c476a23f4e9da4732b59b7d098`.
Its original authoring-time NOT_RUN/pending-vector annotations remain unchanged;
actual preparation/output hashes and results belong to the first receipt.

## Actual tools and cases

Absolute repository-local OSS-suite Icarus/vvp paths and executable SHA256 were
checked against the approved plan. The runner archived plan.json, then eleven
exact input copies before importing the model. All three ASCII vectors were
frozen before any HDL child. Every child had a20-second hard limit with tree
termination and bounded failure cleanup. Name/argv/cwd were checked against the
plan with only its timestamp placeholder substituted. Existing receipts prevent
automatic replay. No child approached its deadline.

| Check | Actual result |
| --- | --- |
| Default core syntax | PASS |
| LEVELS64/TAG32 syntax | PASS |
| Actual itch_order_bbo8 example syntax | PASS |
| LEVELS1/TAG1 compile + simulation | PASS + PASS |
| LEVELS7/TAG8 compile + simulation | PASS + PASS |
| LEVELS64/TAG32 compile + simulation | PASS + PASS |
| Actual example compile + simulation, L2_LEVELS1 | PASS + PASS |

Default/max syntax stderr is empty. Other compiler stderr contains only
inherited/missing timescale warnings for delay-free RTL/dependencies. All four
simulation stderr logs are empty; each run prints its expected PASS marker and
reaches `$finish` with zero exit status. Raw logs and every exact command remain.

## Observed coverage

The independent oracle uses a dictionary keyed by (side,price), integer arithmetic
and max/min for BBO. It does not reproduce the sequential RAM scan, free-slot
selection or RTL commit states. Every completed command compares the complete
response and the entire live RAM map; every expected row must occur exactly once.
This also checks full-state preservation after rejected mutations.

| LEVELS / TAG_W | Commands | Held clocks | Actual future offers | Live resets | Total TB clocks |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 / 1 | 232 | 1392 | 227 | 4 | 3759 |
| 7 / 8 | 259 | 1554 | 254 | 4 | 6744 |
| 64 / 32 | 373 | 2238 | 368 | 4 | 48059 |
| Total | 864 | 5184 | 849 | 12 | 58562 |

The three ordinary command sets contain650 APPLY,113 GET,43 SNAPSHOT,49 CLEAR,
3 INVALIDATE and6 invalid opcodes. Observed status counts are795 OK,18 NOT_FOUND,
9 BAD_DELTA,3 UNDERFLOW,6 FULL,3 OVERFLOW,24 FAULTED and6 BAD_OP. These counts
exclude reset-cancelled work. Each ordinary result is held for six clocks;849
real next fixture commands are offered while the prior response is held and
remain valid/stable through their eventual acceptance.

Cases include64 maximal unsigned32 additions at one price and rejection of a
65th, full64 levels entirely on either side, zero/high-bit/all-one prices,
same-key subtraction validation before addition, same-key net changes, full-table
complete-old deletion and new-key slot reuse, rejected partial-old-plus-new pairs,
best reduction/deletion/replacement, quantities above32 bits, cross-side updates,
locked/crossed books, all supported commands, faulted retirement and recovery.
The maximum64/TAG32 profile is actually simulated, not syntax-only.

Each profile also has one initial reset, giving15 reset activations overall.
Three probes interrupt a pending scan. Two probes (LEVELS7/64) assert reset at
the negative edge after the first confirmed write and before the second write handshake;
LEVELS1 instead interrupts after its single payload write and before metadata
commit. Three probes cancel held successes and three cancel held faults. Reset
is asserted immediately at the observed boundary, held across two rising edges,
and followed by an empty GET/SNAPSHOT and fresh add/get/delete lifecycle. This is
finite whole-epoch cancellation evidence, not rollback or exhaustive reset proof.

The actual composition processes16 state/L2 responses: CONFIG, A/F same-price
aggregation above32 bits, C at an execution price different from resting price,
same-price U, a different-price U whose state commit succeeds but L2 is FULL,
faulted D/QUERY retirement, CLEAR, fresh ask, INVALIDATE, changed-symbol CONFIG,
symbol filtering, fresh bid, missing-order fault and recovery. Its deliberately
smaller one-level L2 produces one natural aggregate failure without force or
fault injection. The TB confirms both flags are invalid, the old aggregate quote
is retained and the upstream new order record remains committed. No rollback
is claimed. Default-eight-level example elaboration is checked separately.

## Evidence closure and limits

Post-run reads verified eleven current input/archived-copy pairs,22 raw logs,
three frozen vectors,four ignored generated VVP images,two tool executables and
both current/archived plan against their hashes. Receipt flags for current
sources, archives, vectors, plan, tools and exact executed plan are all true.
B37_DELIVERY.json maps each executed input to the delivered byte-identical path
and hashes all retained package artifacts except itself and ignored work files.
Only documentation/manifest/delivery metadata changed after execution. Four
generated VVPs remain for root-owned integration cleanup; no worker cleanup,
staging or commit was performed.

Maturity is LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.
No synthesis, PnR, STA, board run, inherited large regression, exhaustive proof,
device fit, power, Fmax or line-rate measurement occurred. INTERNAL RAM/control
fault handling is source-reviewed and not fault-injected. Source-derived response
cycle bounds have no independent timing assertion; TB total run lengths include
source/sink stalls and resets and are not service-rate measurements. Feed parsing,
snapshot acquisition, full-day history, ranked depth and matching remain outside
this core. Recovery still requires a consistent common order/L2 epoch.

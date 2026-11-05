# Finite qualification

Current status: **LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED**.

Authoritative first execution:
`reports/20261105T181105335027Z/results.json`. All9 selected child commands
passed: three syntax/elaboration checks and three compile/simulation pairs.
No failed/retried check occurred. All8 executable/file-list/dependency inputs
and exact copies archived before tool execution still match receipt hashes.
No executable source edit followed qualification. Descriptive documents and
delivery metadata are not tested program inputs.

| Actual check | Scope | Observed result |
| --- | --- | --- |
| Icarus `-g2012 -Wall -tnull` | Default production top | PASS |
| Icarus `-g2012 -Wall -tnull` | QUEUES8/DEPTH16/SLOTS16/TICK_W16/DATA_W64/TAG_W32 | PASS |
| Icarus `-g2012 -Wall -tnull` | Complete default example and canonical FIFO closure | PASS |
| Compile and vvp |1/1/1/1/1/1|438cycles,39commands,3launches,78holds, PASS |
| Compile and vvp |3/3/3/8/17/9|648cycles,60commands,13launches,120holds, PASS |
| Compile and vvp |4/4/4/16/32/8|776cycles,71commands,20launches,142holds, PASS |

Profile columns are QUEUES/DEPTH/SLOTS/TICK_W/DATA_W/TAG_W. Total1862 complete
cycle comparisons,170 control commands,36 launch events and340 held-response
cycles. The independent model additionally records50 clock cycles with an
open queue whose head fails the remaining-window guard. Each profile includes
five asserted reset cycles in three episodes: initialization, a held control
response with queued work, and an owned maximum-cost service reservation
(the one-bit profile necessarily has only cost1). Tests do not force physical
transmission or dynamic-loaded-library tracing.

The reference model uses ordinary deques, integer list-based gate entries,
and selection by modular-distance minimum rather than FIFO RTL/pointers. It
emits all cycle inputs/expectations before any compiler/simulator call. The TB
compares command readiness, held response payload, every launch field, current
calendar/reservation/mask and packed queue counts. Every launch independently
checks permission, open gate, positive fitting cost and no active reservation.
No ordinary ready/valid guarantee is asserted for the native launch qualifier.

Cases cover zero/max cost and duration, minimum duration1, exact-fit entry-end
launch, round-robin selection among eligible heads, nonpower queue/depth/slot
parameters, whole-packet FIFO order, full/empty queues, invalid full32-bit
queue/slot indices, guard deferral, all-zero closed gates, stage-vs-active
isolation, incomplete plan rejection, COMMIT/START busy rejection, stopped
calendar with continuing reservation, oversized-head removal, permission
stalls, held control replies with further queue launches and reset cancellation.
Actual64-bit data and maximum8/16/16 geometry are syntax-checked only; finite
simulation does not certify every parameter combination or arbitrary schedule.

The canonical FIFO remains byte-identical at
`450ea3b252a83e2a214a94cb8c4ade54436c046175880eb31e9f3e2713a71ba6`.
Its dependency is listed once in each package-root source list. Icarus emits
only missing-explicit-time-unit warnings for wrapper/FIFO during TB compiles;
production has no delays and the TB uses explicit1ns/1ps timing. Raw logs and
three vector files are retained. Watchdog/dependency cleanup branches are
source-reviewed, not forced as extra tests. Local successful VVPs remain
ignored for root-owned review/cleanup.

Static review checked guarded descriptor consumption, positive cost/duration
invariants, non-wrapping service decrement, entry-boundary reload, staged-plan
atomic commit, stable captured responses, FIFO CE adaptation and shared reset.
No existing production file was modified.

Synthesis, placement/routing, STA, board operation, formal verification, full
regression, PPA/Fmax/device-fit or actual packet line-rate measurements:
**NOT_RUN**. Hardware remains **HW_UNVERIFIED**.

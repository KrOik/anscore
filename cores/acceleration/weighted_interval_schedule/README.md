# Exact weighted interval scheduling

`weighted_interval_schedule` maximizes the exact sum of unsigned weights of
mutually nonoverlapping signed integer intervals. Each interval is half-open
`[start,end)`, with strictly positive length; adjacency is compatible. Input
order is arbitrary. Equal maximum weights choose the smallest unsigned numeric
selection bitmap, where bit i denotes retained input i. The empty subset is
legal, so an all-zero-weight frame selects nothing. Every retained input is
replayed in arrival order with its selection flag and complete optimal bitmap.

## Interface and numeric contract

One rising-edge clock, synchronous high `rst`; no CE or CDC. Reset cancels
collection, computation and held output, gates ready/valid low immediately,
and clears scalar/read/output registers on the reset edge. Arrays are not
reset; every item read belongs to the current collected frame and every
consumed chain record is gated by its current processed bit. No external
memory, initialization file, vendor primitive or sibling RTL is needed.

`s_valid && s_ready` accepts a token. A producer holds valid and all input fields
until handshake/reset. `s_keep` appends an interval; masked tokens consume no
capacity. The first accepted token captures opaque `s_tag`, including a masked
token. Later tags are ignored. Accepted `s_last` closes the frame even when
masked; a missing tail waits indefinitely until reset. Endpoints are signed
two's-complement integers, weights unsigned integers, with no fixed-point scale,
rounding or saturation. Duplicate intervals are distinct original items.

The collector accepts one token each clock. It drains through the tail after
errors. Error bit0 means more than MAX_ITEMS retained intervals; bit1 means
any retained `start>=end`, including excess intervals. The two errors are
independent and sticky; masked geometry never raises an error. Any error
atomically rejects the entire frame. It emits one status token with keep,
index, endpoints, weight, selected, count, total and bitmap zero, first/last1,
the captured tag and both error bits. A valid empty frame emits the same
status with error0. There is no partial-prefix optimization on an error.

Only one frame is owned at a time; input ready stays low during all work and
replay. `m_valid && m_ready` transfers output. Valid and every output field
stay stable under arbitrary sink stalls. The next input can transfer on the
edge after final result retirement. Computation does not depend on sink ready.
A CE-qualified peer needs an explicit adapter. Output fields when invalid
are unspecified.

| Output | Normal nonempty frame |
|---|---|
| `m_keep,m_first,m_last` | keep1, first/final replay markers |
| `m_index,m_start,m_end,m_weight` | Original index and complete interval |
| `m_selected` | Corresponding selected bitmap bit |
| `m_count` | Retained interval count, repeated |
| `m_total_weight,m_selection` | Exact optimum and full selection bitmap, repeated |
| `m_tag,m_error` | First-token tag, error0 |

| Parameter | Default | Legal |
|---|---:|---|
| MAX_ITEMS (N) | 16 | 1..64 |
| ENDPOINT_W (E) | 16 | 2..32 |
| WEIGHT_W (W) | 16 | 1..32 |
| TAG_W (T) | 8 | 1..32 |

INDEX_W=max(1,ceil(log2N)), COUNT_W=ceil(log2(N+1)),
SUM_W=W+ceil(log2N). The largest total is `N*(2^W-1)` and fits SUM_W;
no total wraps. Illegal static parameters fail elaboration through
`weighted_interval_schedule_invalid_parameters__see_README`.

## Architecture, latency and resource bounds

Original item RAM is never reordered. A serial synchronous-read scan selects
the smallest finish among unprocessed intervals; equal finishes use index.
A second scan selects the best compatible processed endpoint-chain record,
then appends the current interval and updates the global empty-or-chain best.
Positive interval lengths place every predecessor at a strictly earlier finish.
Any optimal nonempty subset has a final interval and an optimal compatible
prefix, proving coverage. Adding the same absent bit preserves numeric mask
order, proving deterministic global tie handling. The engine uses one shared
weight adder and pair comparator, with no multiplier or divider.

For K normal retained intervals, each of K work iterations takes4K+2 clocks:
2K selection-read/evaluate, one setup, 2K predecessor-read/evaluate and one
commit. Two replay-read/load clocks follow. First valid therefore appears
exactly `K*(4*K+2)+2` periods after the accepted tail edge, at most16514 for
K64. Empty/error valid appears immediately after that edge (zero periods).
Earliest transfer is the following rising edge. Subsequent replay items
appear two periods after the preceding transfer, giving transfer spacing3
without stalls. Stalls add their own duration; no unconditional deadline is
claimed. These are FSM schedules, without an operating-frequency claim.

Logical RAM bits are `N*(2*E+W+SUM_W+N)`:1344 default,12672 maximum.
There are two single-read memories; chains have one commit write per interval.
Declared scalar/read/output storage is
`8+2*COUNT_W+3*INDEX_W+4*N+3*SUM_W+6*E+3*W+T` bits:
406 default,830 maximum, excluding inferred RAM and synthesis transformations.
There is no array reset or combinational all-item reduction. Wide mask records,
serial quadratic runtime and tool-dependent RAM inference dominate scaling.
Qualitative risk is LOW default/MEDIUM maximum; device fit, resource counts,
timing, power and hardware throughput are unmeasured.

## Offline use and bounded evidence

From this package, `files.f` closes the core and `examples/schedule16.sv`
instantiates all default ports:

```text
iverilog -g2012 -Wall -tnull -s weighted_interval_schedule -s schedule16 -f files.f examples/schedule16.sv
```

From repository root, `python -B cores/acceleration/weighted_interval_schedule/sim/run.py`
runs only the frozen TEST_PLAN.json finite matrix. Each Icarus/vvp child has a
20-second limit; a timeout is terminal for the check plan. It is never retried
with fewer fixtures or a larger limit. The runner preserves failed attempts,
replaces current status at entry and binds all nonreport package hashes.
Temporary vectors/executables are removed automatically. Only standard-library
Python and installed Icarus/vvp are needed; no network access occurs.

The independent oracle sweeps coordinate events and captures the best feasible
set at each starting coordinate. It does not reproduce the RTL's min-finish
selection or per-interval endpoint-chain RAM recurrence. Every valid frame
with K<=17 is also checked by independent exhaustive conflict-subset enumeration.
The small profile enumerates all ordered positive-length signed2 intervals
with weights0/1 at lengths0..3. Other profiles include arbitrary full-domain
seeded intervals, max sums, nested/duplicate/adjacent intervals, greedy failures,
zero weights, masked metadata/tails, overflow and both geometry errors.

The planned testbench checks every result field via the Python oracle, exact first-valid
latency and exact commit/read totals, stable held outputs, persistent source
offers, and immediate resets in all10 states and reachable middle phases.
The plan follows every reset with a complete fresh frame and full result checks.
N1 plans14 reset probes; each other profile plans18. The maximal64/32/32/32
profile was planned for numerical simulation, but is **NOT_RUN** because the
first profile timed out. All eight planned illegal static parameter checks
are also NOT_RUN. Current qualified results are recorded in verification.json.

Current maturity is **LINT_PASS / HW_UNVERIFIED** for the unchanged core and
example: the first `-tnull` command passed with no diagnostics. **Numerical
status is TIMEOUT_NOT_RUN**, with zero completed profiles. The first N1 vvp
child exceeded20seconds and was stopped. All later profiles/negatives are
NOT_RUN. No timeout retry, fixture reduction or limit increase occurred.
Static inspection found that the testbench send task could sample stale ready
immediately after reset release, then wait while an already-accepted tail
blocked input. A1ns testbench settle was added; it has not been rerun. This is
a test-driver diagnosis, not evidence of RTL functional correctness. The
report preserves the attempted source hashes separately and binds current
package bytes; its only current qualified tool evidence covers the unchanged
core/example/files.f. The runner refuses to retry a retained terminal timeout.

The finite matrix and reset checks above describe intended coverage, not
completed coverage. There is no UNIT_SIM_PASS claim. No synthesis, PnR, STA,
board test or expanded regression is run; finite checks do not prove all legal
input/parameter combinations. SOURCES.md records the pre-RTL source/license
inspection and reuse decision.

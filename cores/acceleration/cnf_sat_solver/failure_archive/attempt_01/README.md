# Exact bounded CNF satisfiability

Original portable RTL, **HW_UNVERIFIED**. The exact current source seal and
`verification.json` own any LINT_PASS / UNIT_SIM_PASS claim. No synthesis,
PnR, STA, power or hardware result is claimed. Before qualification this is
an RTL_CANDIDATE; the example establishes instantiation, not integration.

The service decides arbitrary conjunctions of positive/negative disjunctions
and returns a complete satisfying assignment or normal UNSAT. This adds a
general signed Boolean constraint interface beyond the existing graph-only
clique/colouring and positive union/weight set-cover objectives. It does not
return an UNSAT proof certificate, all models, or an optimization objective.

## Interface and ownership

| Parameter | Default | Legal integers |
|---|---:|---|
| MAX_VARS=V | 8 | 1..16 |
| MAX_CLAUSES=C | 16 | 1..64 |
| TAG_W=T | 8 | 1..32 |

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid,
no CE or CDC. Transfers require valid and ready. Producers hold valid and
their entire payload until transfer or reset. Reset level gates all public
ready/valid low; its active edge cancels command, capture, search and held
response without producing an answer. RAM payload and read-data do not reset.

A command captures full unsigned32 `c_num_vars`, unsigned32 `c_num_clauses`,
`c_error` and `c_tag`. Runtime counts 0..V and 0..C are legal, including zero.
The variable universe is `[0,c_num_vars)`. Counts are validated before any
narrowing or variable shift. Invalid counts return a canonical error response
without owning or consuming rows. A zero-clause command consumes no rows.

A valid positive-clause-count command owns exactly that many row transfers.
Each row carries V-bit `s_positive`, V-bit `s_negative`, `s_last`, `s_error`.
Bit j means literal x[j] or NOT x[j]. Repeated variables are naturally one
bit. Both polarities in a clause make it a tautology, but still undergo the
runtime-domain check. Zero masks form an empty, false clause. Clauses may be
empty, duplicated, reordered or tautological; no clause is silently masked.
An early accepted LAST terminates capture immediately with an error. The
declared final row terminates capture even if LAST is missing, also with an
error. No surplus-row drain follows either terminator; the caller supplies
rows only for an accepted owning command. Missing rows may wait indefinitely.
Upstream and literal errors accumulate through that terminator.

| Error bit | Meaning |
|---:|---|
|0|full32 runtime variable count exceeds V|
|1|full32 runtime clause count exceeds C|
|2|a received clause uses a variable outside the runtime universe|
|3|LAST before the declared final row|
|4|missing LAST on the declared final row|
|5|accepted command or row upstream error|

One held response returns `m_sat`, V-bit `m_assignment`, six error bits and
the owning command tag. On error, sat/assignment are zero. Normal UNSAT also
has sat/assignment zero, with error0. SAT has error0 and a complete assignment
that satisfies every clause; unused high variable bits are zero. Any satisfying
assignment is legal; no global tie order is promised. No output LAST is needed
because the complete answer fits one record. Empty CNF is SAT with assignment0,
also at runtime variable count0. A legal empty clause makes a formula UNSAT.

All result fields stay stable under backpressure. A transaction owns capture,
solve and held output. Neither a following command nor its preoffered row can
transfer before ownership permits it. The next command can transfer on the
edge after response retirement, not on the retirement edge. Rows load at II1.
Input gaps and sink stalls have no finite upper bound. No external memory,
configuration bank, generated ROM or network is needed by production RTL.

## Algorithm, memory and bounds

A serial clause pass handles tautologies and already satisfied clauses first.
An unsatisfied clause with one unassigned variable forces that literal and
restarts the pass. Each propagation assigns a previously unassigned variable.
A falsified clause restores the most recent pending true child, or proves
UNSAT when no pending child remains. A full all-satisfied pass returns the
current values, completing still-unassigned variables with zero. Otherwise
the lowest unassigned variable in an unsatisfied clause branches false first;
the complete true-child assigned/value image is pushed to a synchronous RAM.

Each decision partitions its remaining assignments into false and true
children. Propagation removes only falsifying assignments. Restoring complete
snapshots prevents units from a failed child leaking into its sibling. Every
decision assigns a new variable, so depth is at most V and the full tree has
at most `2^(V+1)-1` nodes. This is exact chronological DPLL without clause
learning, restarts, watch lists, time-limited approximate answers or recursive
hardware. Exhaustion is a real UNSAT result, not an error.

The clause bank has C words of 2V bits; every current row is loaded before
search. The pending bank has V words of 2V bits; every restore follows a push
and synchronous read by that same command. Each bank makes at most one read
OR write per clock. Read and use phases are separate. There is no whole-array
asynchronous read, payload reset, multiplier, divider or vendor primitive.
The maximum combinational mask/unit/priority width is16 bits.

Logical RAM is `2V(C+V)` bits: **384 default /2560 maximum**. With
`CW=max(1,clog2(C+1))` and `DW=max(1,clog2(V+1))`, the actual sequential scalar,
response and RAM read-data declarations total `3CW+DW+9V+T+18` bits:
**117 default /220 maximum**. Combinational branch masks and loop indices
are excluded. Default structural risk LOW, maximum MEDIUM; shallow memories
may map to registers or fragmented RAM. Worst-case service-time risk is HIGH
at the maximum. These are source declaration counts and qualitative judgments,
not LUT/FF/BRAM/DSP, frequency or power measurements.

At each search node at most V propagations restart a pass; a pass takes at
most `2C+3` clocks including setup/completion. Allowing six additional branch,
restore and termination clocks per node plus eight boundary clocks yields:

```text
tail <= (2^(V+1)-1) * ((V+1)*(2C+3)+6) + 8
```

This conservative bound is **164039 default /292681551 maximum clocks** from
accepted final row (or a zero-row command) to first valid, excluding external
waits. Exponential worst-case latency is an explicit limit of this bounded
service. A held response and the next command's capture add further time.
No hardware clock rate or measured throughput is implied.

## Offline use and finite qualification

From this directory `files.f` lists the sole production source. The complete
default wrapper is in `example/cnf8.sv` and `example/files.f`.

```text
iverilog -g2012 -Wall -tnull -s cnf_sat_solver -f files.f
iverilog -g2012 -Wall -tnull -s cnf8 -f example/files.f
```

The delivered fixture plan fixes five V/C/T profiles: 1/1/1,2/4/3,4/8/5,
8/16/8,16/64/32. Its234 main commands include empty and zero-variable formulas,
empty clauses, positive/negative units, tautologies, a tautology/unit trap,
unit chains, nested decisions, sibling unit rollback, complete assignment
blockers, full capacity, variable/clause permutations, planted and seeded
formulas, full32 count failures and independent framing/literal/upstream errors.
Maximum parameters have numerical fixtures; no profile is compile-only.

The primary oracle uses Python integer truth-table columns for all assignments,
ORs literals within each clause and ANDs clauses. It does not propagate or
backtrack. Through four runtime variables, scalar assignment enumeration
independently crosschecks SAT status, solution count and the smallest witness.
The TB independently
evaluates every returned assignment against the original clauses and checks
runtime high bits, canonical failures, exact transfer counts, original rows,
bank ports/ownership, decision masks, pending depth and the conservative bound.

Main command and row streams preoffer real subsequent inputs and keep them
stable through actual acceptance. Main responses are held for at least five
blocked edges. Seventy immediate reset probes cover every reachable state,
unit/tautology evaluation, empty/nonempty pop, nested pending and held SAT/error.
V1 decision/restore and small-domain depth2 exclusions are explicit. Reset is
asserted immediately after the real predicate is observed, before another active
edge. Every reset is followed by a complete full-C-row fresh formula, all-row
image checks, a nonzero upper-variable witness, held result, and a real queued
empty-CNF command through acceptance and complete response retirement.

`TOOL_PLAN.json` fixes29 child invocations: two syntax checks, five builds,
ten main/reset simulations, six invalid-parameter builds and six named expected
runtime rejections. `SOURCE_SEAL.json` binds all sources, fixtures and both
plans before the first HDL child. `run_tests.py --run` refuses an existing
receipt; each child has a hard20-second limit. First failure/timeout stops the
matrix and preserves later NOT_RUN records, exact raw stdout/stderr and existing
artifacts. No retry, raised limit or smaller replacement workload is automatic.
Successful temporary vvp outputs alone are removed by exact known paths.
`--audit` reads hashes and evidence without invoking HDL or either oracle.

This is finite functional/protocol qualification, not exhaustive schedules,
formal proof or hardware validation. B25's Git-read checker timeout is neither
retried nor inherited as a result for this package. Original code is Apache-2.0
under included LICENSE/NOTICE; SOURCES.md records reference-only provenance.

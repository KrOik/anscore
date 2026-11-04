# Sparse signed minimum-cost perfect assignment

`min_cost_assignment` finds an exact minimum-cost bijection between N rows and
N columns. Each pair can be forbidden; allowed signed integer costs may be
negative. Success publishes N row-ordered assignments, the original cost sum,
and a complete dual certificate. Infeasibility publishes a Hall-deficient
row/column set. This adds cost optimization and certificates to the repository's
unweighted bipartite matcher; it is not a rectangular assignment or max-flow API.

## Transaction contract

All transfers use ordinary rising-edge valid/ready on one clock. `rst` is
synchronous active-high; ready and valid are also suppressed combinationally
while reset is high. There is no CE, CDC, external memory or dynamic configuration.
Use an explicit adapter for a CE-qualified stream. Hold all offered input fields
stable until `s_valid && s_ready`; hold sink ready independently of source valid.

After reset and each result retirement, N*N clocks serially clear the matrix.
Ready is then high in capture, accepting one token each clock until an accepted
`s_last`. The first accepted token owns the tag, including a masked token; later
tags are ignored. A kept token assigns `(row,column)` the signed cost and allowed
bit. Last assignment wins; allowed=0 removes that pair. Masked tokens ignore all
pair fields. A single masked tail describes an empty graph. There is no implicit
tail, fixed token count, timeout or frame-size limit.

Both indices are unsigned **32-bit** and checked before addressing. Any kept
out-of-range index rejects the entire frame, even when allowed=0. The core still
drains to the accepted tail. It produces one masked BAD_INPUT status with zero
payload and the first tag. No partial assignment is emitted. Input ready stays
low during solving, output and clearing; arbitrary output backpressure is legal.

| `m_status` | Output |
|---|---|
| 0 OK | N kept records, row 0..N-1; last only on row N-1 |
| 1 BAD_INPUT | One masked last record; all numerical and Hall fields zero |
| 2 INFEASIBLE | One masked last record; Hall bitmaps, other numerical fields zero |

Every field and valid remains stable while output is blocked. Each success
record carries its assigned column, original signed cost, common signed total,
row dual U and that matched column's dual V. Collecting all records reconstructs
U and V. Every allowed pair satisfies `U[i]+V[j]<=cost[i][j]`; matched pairs have
equality and `sum(U)+sum(V)=m_total`. These conditions certify optimality.
Hall rows R and columns C satisfy `|R|>|C|`, and all allowed neighbors of R lie
in C. Forbidden pairs impose no dual inequality. Ascending scans resolve equal
slacks deterministically, but no lexicographically minimal matching is promised.

Reset cancels partial capture, synchronous read, tree/slack/potential work,
augmentation and held results at the active edge. Public output fields clear;
the matrix is not reset in parallel. The next full clear completes before any
read, and scratch entries are serially initialized before use. Replay canceled
work if required. An input offer present at reset is not accepted.

## Exact representation and structure

| Parameter | Default | Legal |
|---|---:|---|
| N | 8 | 1..32, square problem |
| COST_W | 16 | 1..24, two's-complement integer costs |
| TAG_W | 8 | 1..32 |

Derived port-width parameters must retain their defaults: `INDEX_W=max(1,clog2 N)`,
`TOTAL_W=COST_W+clog2 N`, `DUAL_W=COST_W+2*clog2 N+3`. Illegal parameters fail
elaboration through `min_cost_assignment_invalid_parameters__see_README`.
There is no rounding, saturation, floating point or fixed-point scale.

The serial integer Hungarian architecture shifts each cost by 2^(COST_W-1),
implemented by XOR of its sign bit. This preserves optimal square assignments
while making every initial reduced cost nonnegative. A synchronous-read matrix
stores allowed plus shifted cost. Small indexed register arrays store potentials,
matching, predecessor, slack and tree membership. Explicit finite bits represent
unreachable slack; there is no finite sentinel masquerading as infinity.

Let L=clog2 N and Cmax=2^COST_W-1. Nonnegative deltas preserve dual feasibility.
Before root r, every potential is at most the previous shifted optimum, bounded
by (r-1)*Cmax: each receives a delta at most once per tree step. During this root,
an unused column's negv is unchanged, so every new finite slack/delta is at most
r*Cmax. There are at most r tree steps, hence even a final **failing** root has
potentials and cumulative deltas at most (r*r+r-1)*Cmax. Thus cost+negv is at
most (N*N+N)*Cmax. `PW=COST_W+2*L+2` covers these with margin. The cumulative
shifted-total workspace also has PW bits. Original duals are
`U=u-2^(COST_W-1)`, `V=-negv`, using signed PW+1. On success the shifted optimum
fits COST_W+L unsigned bits. Subtracting the static N*2^(COST_W-1) offset at
PW+1 signed width before narrowing gives the exact original TOTAL_W-bit total.
At N32/COST_W24, total is signed29 and duals signed37. Minimum cost -1 at W1
and N1 are supported without illegal slices or wrapped sentinel indices.

The matrix has N*N*(COST_W+1) logical bits: default **1088**, maximum **25600**.
Scratch arrays have `3*(N+1)*PW+2*(N+1)*clog2(N+1)+2*(N+1)+N*INDEX_W`
bits: default **762**, maximum **4186**, excluding scalar/read/output registers.
The matrix has serial writes and synchronous reads on disjoint states, without
read/write collisions. Scratch arrays use dynamic register reads and serial
writes; they are not claimed to infer BRAM. No variable multiplier, divider,
vendor primitive, payload frame buffer or replicated edge comparator is present.
Constant row-address products can map to shift/add. Large register selectors
and the reduced-cost add/subtract/compare path dominate qualitative risk.
Default risk **LOW**, parameter maximum **MEDIUM**; these are architectural
judgments, not measured resources, timing or power.

With an accepted tail at cycle zero, a conservative first-valid observation
bound is `(N+1)+N*(N+2)+(3*N+5)*N*(N+1)/2+N+3` clocks. This includes scratch
initialization, at most r tree visits/augmentation steps for root r, inversion,
read/load and a sampling margin. Errors can finish sooner. Remaining success
records have two preparation clocks after the previous handshake; continuous
ready yields one transfer every three clocks. Clearing after final retirement
takes N*N clocks. Capture gaps and output stalls are unbounded by the core;
there is no unconditional transaction-time or clock-frequency guarantee.

## Offline finite evidence

`python -B sim/run.py` uses standard-library Python and installed Icarus/vvp;
each tool child is limited to 20 seconds. `verification.json` binds exact source,
TB, wrapper and runner bytes. Six profiles cover N1/W1 through N32/W24, signed
extrema, all 3^4 sparse N2 assignments, forbidden/removal/repeated assignments,
masked full-width bad indices, atomic rejection, tie determinism and true stalls.
An independent unit-capacity residual min-cost-flow oracle uses Bellman-Ford
augmentations. Exhaustive permutations cross-check N<=5; every published primal,
dual or Hall certificate is separately checked. The first-result bound is
checked conservatively, not asserted as exact latency. Eighteen immediate phase
cancellations per profile each precede a fresh complete diagonal solve: all 16
states, plus actually held normal/error outputs with blocked source offers.
The N1 profile includes held singleton output. No extra active edge occurs
between detecting a cancellation boundary and asserting reset.

Maturity: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED** for the hash-bound finite
checks. No synthesis, placement/routing, STA, board work, PPA or expanded
regression was run. `examples/assignment4.sv` is an offline fixed N4 wrapper;
its synthesis/hardware integration remains unverified. Root LICENSE and NOTICE
cover this original Apache-2.0 package; see SOURCES.md for preimplementation
semantic and actual upstream source/license inspection.

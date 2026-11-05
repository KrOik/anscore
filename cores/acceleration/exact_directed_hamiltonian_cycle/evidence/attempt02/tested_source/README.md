# Exact directed Hamiltonian cycle

Original bounded FPGA RTL for a minimum-cost directed cycle visiting every
vertex exactly once, rooted at vertex0. Missing edges, signed costs, infeasibility
and an ordered tour witness are part of the interface. Assignment can return
disjoint subtours and matching can leave vertices uncovered; neither implements
this result contract. This is an exponential small-graph engine.

Current authoring status: RTL_CANDIDATE, all preparation/lint/simulation NOT_RUN,
HW_UNVERIFIED. No synthesis, PnR, STA, board, power or physical fit evidence.
See [COST.md](COST.md) and [SOURCES.md](SOURCES.md).

## Parameters and exact arithmetic

NUM_NODES N=2..12 (default8), WEIGHT_W W=2..24 (default16), TAG_W=1..32
(default8). IW=ceil(log2 N), CW=ceil(log2(N+1)), SCORE_W=W+IW. Unsupported
parameters instantiate `exact_directed_hamiltonian_cycle_invalid_parameters__see_README`.
These are semantic rejects, not silently clamped configurations. Internal
declaration clamps only keep the diagnostic branch well formed.

All W-bit signed edge values, including zero and minimum negative, are legal.
SCORE_W signed bits cover any sum of at most N edges, including
`-N*2^(W-1)`. No rounding, saturation, numeric tolerance or wraparound occurs in
a valid mathematical result. A two-node cycle contains both distinct directed
edges. Self-loops are invalid input, even for deletions.

## One-owner ready/valid interface

One rising-edge clock, synchronous active-high rst. A reset edge cancels the
partial/solving/held frame and starts graph initialization. Both handshake
outputs are low while rst is high. No public CE or CDC is present.

An input handshake is s_valid && s_ready. Initialization blocks admission for
N*N clocks, clearing edge presence; RAM payloads elsewhere are not bulk reset.
In LOAD, each accepted beat has these fields:

| Field | Meaning |
|---|---|
| s_from/s_to | Full unsigned32 vertex numbers; both checked before truncation |
| s_weight | Signed W-bit integer |
| s_keep | When1, assign/delete the indicated directed edge |
| s_present | When keep1, 1 stores weight and0 removes the edge |
| s_last | Ends the owner frame on this accepted beat |
| s_tag | Only the first accepted beat is captured, including a keep0 beat |

Repeated assignments/deletions are last-wins. A keep0 beat ignores endpoints,
weight and present but still carries last and possibly the first tag. At least
one beat is needed; a keep0/last1 beat represents an empty graph. An arbitrary
finite number of assignments may precede last; there is no implicit token cap.
If any kept endpoint is >=N, error1 is latched. A kept self-loop latches error2.
Endpoint error has priority over loop error regardless of their order. Errors
drain through the accepted last and then emit a summary; later edge writes in
that invalid owner are inhibited. No next owner enters while solving/emitting.

An output handshake is m_valid && m_ready. All fields remain stable while valid
and stalled. On success, exactly N+1 records have keep=feasible=1, error=0,
position=0..N and the ordered vertex at that position. Vertices0 andN are both0;
every other vertex appears once. All records repeat the first tag and signed
exact m_cost. last is1 only at positionN. No feasible cycle emits one canonical
record with keep=feasible=0, last=1, error=0 and all numeric fields zero except
tag. Input error emits that same summary with error1/2. Meaningful outputs are
defined only while valid. Summary feasibility and error are separate concepts.

After the last success or summary retires, graph initialization begins again;
admission resumes after N*N initialization clocks. There is no overlap or
mutation interleaving. A future first beat may be offered while the current
last is stalled; s_ready stays low and it cannot alter the owner.

## Algorithm and deterministic witness

K=N-1 mask bits represent nodes1..N-1. D(mask,j) is the minimum cost of a path
from0 visiting exactly mask and ending at j. Singleton values use edge0->j.
For a nonsingleton, scan included predecessors i increasingly and evaluate
D(mask without j,i)+edge(i,j). Missing paths/edges cannot be candidates. Masks
increase numerically, so every predecessor entry has already been written in
this owner. Excluded endpoints and mask0 entries are never read.

Close the full mask with edge(j,0), scanning j increasingly. Only strict cost
improvement changes a saved parent or final endpoint. Among equal-cost tours,
this selects the lexicographically least *reversed* sequence of internal
vertices. It does not claim the forward lexicographically least tour. Synchronous
parent reads reconstruct backward into a tiny packed vector, then emit forward.

Two single-port synchronous banks hold edges and packed score/valid/parent
entries. A shared signed adder feeds a registered candidate and comparator.
No multiplier, divider, combinational DP lookup, replicated transition lanes,
external RAM, vendor primitive or unknown memory initialization is required.
The exact dependency closure is the local RTL in files.f. Both files.f and
example/files.f use paths relative to this package root; the full-port default
example is [tour8.sv](example/tour8.sv).

## Finite qualification source plan

[CASE_PLAN.json](CASE_PLAN.json) lists five individual profiles and40 named
fixed normal cases. Each is replayed under two declared stream schedules.
The independent reference directly searches complete tours only in the fixed
small graphs, never the RTL subset recurrence. Its tie key is cost plus the
reversed witness. Maximum-profile graphs are sparse one/two-ring certificates;
there is no factorial dense maximum-profile search or input Cartesian sweep.
Six reset jobs are limited to two small profiles, with reachable named capture,
DP, sum, trace and held-output predicates. Exact fixture and raw row counts
will be recorded by the single future preparation, not guessed from source.

Every future compiler/simulator tree has a hard20-second limit, first failure
stop, complete raw streams and receipts, no automatic retry. Preparation is a
separate single-invocation gate. No inherited numerical matrix or legacy source
checker is invoked. Current source authoring does not confer a test PASS.

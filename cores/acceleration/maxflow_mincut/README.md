# Exact integer maximum flow and minimum cut

`maxflow_mincut` accepts a directed capacity graph and returns an exact maximum
single-commodity flow, its value, and a source-side minimum cut. General cycles,
antiparallel edges, zero capacities and arbitrary distinct terminals are legal.
All optimization runs in bounded RTL memories/controllers. The caller does not
provide paths, an initial flow or a precomputed cut.

## Graph and numerical contract

NUM_NODES is a static vertex set 0..NUM_NODES-1. Each retained input token
assigns unsigned integer `s_capacity` to directed pair `(s_from,s_to)`.
**The last assignment to a repeated pair wins**, including zero, which removes
capacity. This is a simple directed graph update stream, not parallel-edge
summation. The caller must aggregate parallel capacities if needed. Reverse
capacity requires a separate token. Self-loop capacities are retained for
replay but carry zero flow. Missing pairs have zero capacity. Arbitrarily many
updates may be streamed: there is no retained-edge count or prefix limit.

The first accepted token atomically captures full unsigned 32-bit `s_source`,
`s_sink` and opaque `s_tag`, even when masked. Later terminal/tag fields are
ignored. `s_keep=0` ignores pair IDs/capacity; `s_last=1` closes the graph even
when masked. An empty graph is one masked tail. Missing last waits until reset.

| `m_error` bit | Independent sticky predicate |
|---|---|
| 0 | Any kept edge has from or to >= NUM_NODES |
| 1 | First source or sink >= NUM_NODES |
| 2 | First full-width source equals sink, including equal invalid IDs |

IDs are checked before narrowing. Any error rejects the **entire graph**:
one token has keep=0, first=last=1, from/to/capacity/flow/total_flow/cut zero,
and captured source/sink/tag plus all error bits. Valid updates before/after
an invalid edge are drained through the tail but never published as a prefix.

For a valid graph, exactly NUM_NODES squared tokens replay every ordered pair
in row-major `(m_from,m_to)` order, including zero-capacity pairs. keep=1 marks
this dense matrix result, not positive capacity or positive flow. Capacity is
the final assigned capacity. `m_flow` is an exact nonnegative feasible flow:
0<=flow[u,v]<=capacity[u,v], flow[u,u]=0, and never both flow[u,v]>0 and
flow[v,u]>0. This canonical cancellation convention preserves net flow.
Nonterminal net flow is zero; net source outflow and sink inflow equal
`m_total_flow`. No particular minimum-cost, acyclic or lexicographically
smallest maximum flow is promised.

`m_cut[i]=1` means vertex i is reachable from the source in the final residual
network. The sink is outside this set, and capacity crossing out of the set
equals total_flow, certifying optimality. The cut, total_flow, full captured
terminals/tag and zero error repeat on every token; first/last mark matrix
ends. Ascending FIFO BFS neighbors and deterministic updates give identical
flow/cut for the same final matrix and terminals, independent of equivalent
update ordering. Different maximum-flow algorithms may choose other solutions.

| Parameter | Default | Legal values |
|---|---:|---|
| NUM_NODES | 8 | 2..32 |
| CAP_W | 16 | 1..24 |
| TAG_W | 8 | 1..32 |

All capacities/flows are unscaled unsigned integers, without rounding,
saturation or modulo arithmetic. NODE_W=ceil(log2(NUM_NODES)); queue pointers
have ceil(log2(NUM_NODES+1)) bits. FLOW_W=CAP_W+ceil(log2(NUM_NODES)) covers
the bound `(NUM_NODES-1)*(2^CAP_W-1)`. Residuals have CAP_W+1 bits because
antiparallel capacity plus canceled flow can reach `2*(2^CAP_W-1)`.
Illegal parameters fail elaboration via unresolved
`maxflow_mincut_invalid_parameters__see_README`. Derived widths are local.

## Clock, reset, ownership and latency

Every port uses rising-edge `clk`, ordinary valid&&ready transfer, synchronous
high `rst` and no CE/CDC. Hold all source fields until accepted. Legacy
CE-qualified interfaces require an adapter. Reset gates public ready/valid
low immediately and cancels current capture, arithmetic or held results at its
active edge. The entire graph is discarded. Peers must replay canceled work.

Reset and result retirement start a serial NUM_NODES squared clock clear sweep
before input reopens. There is no parallel array reset or initialized ROM.
Collection accepts one update per clock. Computation and output block new
input; one graph is in flight. All output fields and valid remain stable under
backpressure. Output fields outside valid have no transaction meaning. A normal
always-ready matrix emits one token every two periods; an invalid graph emits
only its status token. Sink stalls extend completion without a time limit.

The core uses Edmonds-Karp shortest augmenting paths. A FIFO BFS marks each
vertex when enqueued, saves one parent and path bottleneck, and scans ascending
neighbors with a synchronous graph read plus check. A found sink starts a
backward parent walk: forward read/subtract/write and reverse read/add/write
are separate phases. Each augmentation increases the value by a positive
integer. The final failed BFS supplies the residual-reachability cut.

Let N=NUM_NODES, A be the actual successful augmentation count and F the final
flow value. From an accepted valid tail to first result valid, a conservative
bound in periods is

```text
(A+1)*(2*N*N+N+2) + 6*A*(N-1) + 1
```

Since A<=F, replacing A with F is also a valid bound, checked from the independent
reference value in each finite test. This can be very loose for large integer
capacities. Each BFS has at most N dequeues and N squared edge scans; each
simple path has at most N-1 edges. Invalid status valid appears immediately
after the accepted tail (zero periods); earliest transfer is the next edge.
These are controller schedules, not measured hardware frequency or rates.

The graph RAM packs `{original_capacity,residual}` and performs at most one
read or write per clock. There is no read-during-write collision dependency.
Queued vertices, parents and bottlenecks are owned by the current BFS, written
before being read; scratch arrays need no reset values. Seen-on-enqueue bounds
the queue at N. Parent paths have no repeated vertex. During augmentation,
paired residuals sum to their two original capacities, so subtraction cannot
underflow and reverse addition fits CAP_W+1. The source is already seen and
the search stops at the sink, preserving the total-flow invariant.

Logical graph plus scratch-array bits, excluding scalar/read/output registers,
seen/cut bitmaps and control, are

```text
N*N*(2*CAP_W+1) + N*(2*NODE_W+CAP_W+1)
```

This is 2,296 bits by default and 51,296 bits at maximum parameters. Small
scratch arrays use indexed reads; BRAM inference for them is not claimed.
No variable-by-variable multiplication, division, vendor primitive, external
memory or sibling source is required. Address strides use a static N. Qualitative
resource risk is LOW by default and MEDIUM at maximum because of graph width,
memory inference and indexed scratch selection. Actual mapping, utilization,
device fit, Fmax and power are unmeasured. Serial search trades sustained rate
for a small arithmetic datapath; it is not a continuous routing fabric.

## Offline example, finite evidence and maturity

`files.f` is relative to this package root and contains one production file.
`examples/flow8.sv` exposes every default port. Its evidence is syntax only:

```text
iverilog -g2012 -Wall -tnull -s maxflow_mincut -s flow8 -f files.f examples/flow8.sv
```

From the repository root run:

```text
python -B cores/acceleration/maxflow_mincut/sim/run.py
```

Only Python's standard library and existing Icarus/vvp are needed. Every tool
child has a 20-second timeout. Task vectors, actual results and executables use
an automatically removed temporary directory. `verification.json` records
commands, six exercised source hashes, vectors and actual-result hashes; the
cumulative manifest also binds the prose. All local text is UTF-8 with LF.

The reference value uses an independent push-relabel preflow/discharge solver,
without BFS augmenting paths. At N<=8, exhaustive source-side cuts independently
cross-check the value. Published flows are additionally checked for capacity,
canonical cancellation, every vertex's conservation, exact value, cut capacity
and full residual reachability reconstructed from those flows. These primal
and cut certificates validate complete outputs without requiring an oracle
to choose the RTL's particular maximum flow. Equivalent final-graph replays
also check deterministic complete solutions.

Seven actual `(N,CAP_W,TAG_W)` profiles are `(2,1,1)`, `(3,1,3)`, `(3,2,8)`,
`(5,4,8)`, `(8,16,8)`, `(16,8,16)` and `(32,24,32)`. They passed 1,120 graphs
and 60,061 result tokens. The N3 profiles enumerate every off-diagonal binary
and ternary capacity matrix (64 and 729 respectively). Fixtures cover empty
graphs, self-loops, zero updates, last-wins replacement, cycles, antiparallel
maximum capacities, reverse-only rerouting, disconnected terminals, changed
later metadata, masked tokens, independent/multiple errors and seeded graphs.
The largest configuration is actually simulated.

Each of the fourteen controller states is canceled immediately at an observed
boundary in every profile (98 probes), including partial clearing, forward
and reverse updates, and a held result with a blocked next-frame offer. Each
cancellation is followed by a checked fresh empty graph. Source and sink drivers
are independent; source stability and complete held outputs are monitored.
Every main result, including singleton error status, is held for three active
clocks. Six illegal configurations must fail with the named guard. All 22
tool records met their expected exit status; positive diagnostics were empty.

Maturity is LINT_PASS + UNIT_SIM_PASS, with the example an INTEGRATION_CANDIDATE
and all hardware HW_UNVERIFIED. No synthesis, PnR, STA, board test or expanded
regression has run. Finite tests do not prove all graphs or legal tuples.

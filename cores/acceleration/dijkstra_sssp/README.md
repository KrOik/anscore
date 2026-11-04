# Exact single-source shortest routes for a directed nonnegative graph

`dijkstra_sssp` accepts a bounded directed weighted graph and one source vertex,
then returns every vertex's exact shortest distance, reachability and one
shortest-path predecessor tree. Zero-weight edges and cycles are supported.
This adds general directed single-source routes, distinct from undirected
minimum spanning forests, bipartite matching and grid-constrained image seams.
There is no all-pairs result, negative weight, dynamic graph update, path-token
reconstruction or external graph memory interface.

## Framing, graph semantics and numeric contract

All ports use one rising-edge clock. `rst` is synchronous active high and gates
public ready/valid low. There is **no CE**, CDC or runtime configuration bank.
Ordinary ready/valid transfer occurs on valid&&ready. A producer must hold every
input field while stalled; a CE-qualified neighbor needs an explicit adapter.

| Input | Meaning |
| --- | --- |
| `s_from/s_to` | unsigned 32-bit directed edge IDs, checked before truncation |
| `s_weight` | unsigned WEIGHT_W-bit integer cost; zero is an ordinary weight |
| `s_keep` | include this edge when 1; ignore its ID/weight when 0 |
| `s_last` | end this graph, including on an excluded or invalid edge |
| `s_source` | unsigned 32-bit source, captured on the first accepted token |
| `s_tag` | opaque metadata, captured on the first accepted token |

Later source/tag fields are ignored. A masked first token still supplies both.
An edgeless graph uses one keep=0,last=1 token. A missing tail leaves capture
open until reset; there is no timeout or implicit restart. Edges are directed:
reverse connectivity needs a second token. Parallel edges merge by minimum
weight, independent of arrival order. Positive self loops do not change the
zero distance to their own vertex. There is no edge-count overflow: up to one
minimum weight per ordered vertex pair is retained, and arbitrarily many
parallel tokens may be drained. Matrix capacity is the elaborated vertex set.

An included edge with either ID>=NUM_NODES is ignored and latches error bit0.
Distances still describe the graph of valid included edges; this status is not
whole-graph rejection. Masked invalid IDs do not latch that error. If the first
source is >=NUM_NODES, error bit1 is set and the entire graph returns all
vertices unreachable, zero distances and no parents. Both error bits can be
set. No invalid source is silently truncated or aliased to a legal vertex.

After the tail, exactly NUM_NODES output tokens appear in ascending vertex-ID
order. New input is blocked until they retire and the next matrix clear ends.

| Output | Meaning |
| --- | --- |
| `m_vertex` | current vertex ID |
| `m_reachable` | a directed path from the valid source exists |
| `m_distance` | exact unsigned shortest distance; zero if unreachable |
| `m_parent_valid` | true for every reachable vertex except the source |
| `m_parent` | predecessor ID when valid, otherwise zero |
| `m_source` | complete original 32-bit source, including invalid values |
| `m_error[1:0]` | invalid source / ignored invalid included edge |
| `m_first/m_last` | first/final vertex token, both true when NUM_NODES=1 |
| `m_tag` | captured first-token tag, repeated on every result |

Unreachable zero and reachable distance zero are distinguished by reachability.
The source is reachable at distance zero and has no parent. Every tree edge
satisfies distance(parent)+weight(parent,vertex)=distance(vertex); following
parents reaches the source, including with zero-cost cycles. The core does not
return a start/end path stream; callers may store results and walk this tree.

At every step the lowest unsettled distance is chosen, with lowest vertex ID
breaking equal distances. Neighbors are visited in ascending ID order. Only a
strict distance improvement changes a parent; equal-cost later candidates leave
it unchanged. This fully specifies the tree for a final adjacency matrix, but
does not claim lexicographically smallest paths or smallest parent IDs. Parents
always point from a newly improved unsettled vertex to an already settled one,
so settlement rank proves acyclicity even when distances are equal at zero.

For N=NUM_NODES, W=WEIGHT_W and B=max(1,clog2(N)), NODE_W=B and DIST_W=W+B.
A shortest path can be simple and has at most N-1 edges, so its cost is at most
(N-1)*(2^W-1). Even the conservative trial bound N*(2^W-1) fits DIST_W, including
N=1. The adder retains an extra carry before comparison/narrowing. Reachability
is a separate bit, not a reserved maximum-distance sentinel. All legal costs
are exact integers: no scaling, rounding, numeric saturation or distance-overflow
status exists. Negative or fractional costs require a different interface.

## Reset, backpressure and storage ownership

Reset cancels capture, processing and any held/partially delivered output graph.
It clears control/public status, then overwrites one packed edge per active
clock for N*N clocks after deassertion. Commands are blocked through that sweep.
Node RAM is not reset in parallel: all N node records are initialized after
every accepted graph tail before any node is consumed. No stale graph can leak
through an abort. Peers must replay the canceled graph and discard any partially
delivered output set; there is no canceled-completion token.

All output fields and valid remain stable while valid&&!ready. Reset overrides
that hold. Fields have no specified meaning outside valid. There is one graph
in flight; capture, solve, output and next-matrix clear do not overlap. A sink
that never accepts can block completion indefinitely. No background access,
coherency, external-memory response, packet retransmission or host service is
assumed.

## Parameters, architecture and service

| Parameter | Default | Legal values |
| --- | ---: | --- |
| NUM_NODES | 16 | 1..64 |
| WEIGHT_W | 16 | 1..24 |
| TAG_W | 8 | 1..32 |

Derived widths are localparams. Illegal public parameters fail elaboration via
the named unresolved `dijkstra_sssp_invalid_parameters__see_README` instance.

A synchronous packed adjacency RAM stores {present,weight}; a synchronous node
RAM stores {visited,reachable,parent_valid,parent,distance}. A valid included
edge uses one read clock and a separate minimum/write clock; masked or invalid
edges need only the capture clock. Thus legal edges have a two-clock admission
interval. Reads and writes of either RAM occur in exclusive states; no device
read-during-write behavior is assumed. There are no parallel whole-array reads
or payload reset trees. One node/edge pair is examined at a time.

The node selector and relaxation datapath share stored scalars rather than
replicating a priority queue or N-way minimum tree. A heap-based alternative
would require graph state plus decrease-key support or bounded stale entries;
the existing command heap offers push/pop/peek/clear but not decrease-key.
For this bounded dense matrix, sequential scans keep closure and storage
predictable. The old heap and graph cores remain unchanged. There is no runtime
multiply/divide for path arithmetic; row addressing uses multiplication by the
elaborated constant N. Actual constant-address mapping is unmeasured.

Logical RAM bits are N*N*(W+1)+N*(DIST_W+NODE_W+3): **4784** at default and
**104896** at maximum. Scalar read registers, selection state and outputs are
additional. There is no ROM/init data, vendor primitive, external storage or
runtime download. Actual BRAM/LUTRAM inference and 25-bit maximum edge packing
are unmeasured. Qualitative risk is **LOW** by default and **MEDIUM** at maximum,
due to memory size/packing, serial work and variable-address control. Expected
paths include the distance add/compare and fixed-stride address logic. No actual
area, device fit, frequency, power or timing result is claimed.

Let R be the number of reachable vertices for a valid source, and delta=1 if
the accepted tail is an included legal edge (its RAM write still needs a clock),
otherwise delta=0. First valid appears after
`delta + R*(4*N+1) + 3*N+2` periods from that tail. This includes N node-init
clocks, R selection/relaxation sweeps, one final no-candidate sweep and output
read. For an invalid source it is `delta+N+1`. All finite cases check these
behavioral latencies. Once output begins, vertex results have a two-clock
interval without stalls. Each held-output clock extends service. The next graph
also waits for N*N matrix clearing clocks. No continuous per-clock graph or
unconditional end-to-end completion rate is promised.

## Offline example and finite verification

`files.f` contains the sole production core. `examples/routes16.sv` exposes the
default 16-node byte-tag interface. From the package root:

```text
iverilog -g2012 -Wall -tnull -s dijkstra_sssp -f files.f
iverilog -g2012 -Wall -tnull -s routes16 -f files.f examples/routes16.sv
```

The example is **INTEGRATION_CANDIDATE**, syntax compiled only. No sibling RTL,
generator, include, ROM or network dependency is needed after checkout.

From the repository root run `python -B cores/acceleration/dijkstra_sssp/sim/run.py`.
Each subprocess has a 20-second limit. Deterministic vectors/binaries use an
automatically cleaned task-specific temporary directory. The supplied Python
standard-library oracle performs synchronous Bellman-Ford passes, with no
visited set or priority selection. Every N<=5 fixture also cross-checks an
independent all-pairs min-plus computation. Every RTL output distance/status is
compared, and the TB verifies each parent edge and source-reaching acyclic tree.
Hand-derived chain/dense/tie fixtures check exact parents; 35 same-graph edge
reorder/duplicate replays check full tree determinism, rather than computing an
expected parent using another Dijkstra implementation.

Seven actual (N/W/tag) profiles are 1/1/1,2/3/1,3/1/3,5/4/8,16/16/8,
31/12/16,64/24/32. They contain **1044 graphs and 7787 output tokens**, with
**906** all-pairs cross-checks. The N=3/W=1 profile enumerates all 729 off-diagonal
adjacency matrices with absent/zero/one edges; each matrix uses one cycling
source, not every source/matrix pair. Other cases include empty, disconnected,
full, zero-cycle, parallel, self-loop, nonpower-of-two and random graphs, masked
metadata, 32-bit invalid IDs/source and both error bits. The maximum profile
actually simulates a 63-edge maximum-weight chain with distance **1056964545**.

Sources insert gaps and hold tokens under admission stalls. Every vertex result
is deliberately held for three active clocks, including singleton outputs.
Each profile cancels all eleven FSM phases at an observed boundary using
reset_now immediately, including the N=1 one-clock matrix-clear phase. These
77 probes are finite phase checks, not arbitrary-cycle or fault proofs. Six
invalid parameter settings are rejected. There are **22** actual tool records;
successful syntax/simulation commands have no diagnostics. The version-query
record is retained separately from functional claims.

`verification.json` binds six implementation/test/example files to SHA256;
this README and SOURCES.md are additionally bound by the cumulative snapshot.
Current maturity is **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**. No synthesis,
PnR, STA, board test or expanded regression is run. Source/license and semantic
preflight details are in [SOURCES.md](SOURCES.md). All package text is LF.

# Signed weighted minimum spanning forest

`kruskal_msf` accepts an undirected edge-list transaction and returns its minimum
spanning forest, including the component count for isolated vertices. It
composes the existing `binary_heap_queue` and `disjoint_set_union` RTL without
modifying them. The wrapper adds graph framing, capacity/error policy, ordered
edge results and an exact signed-weight summary. Parallel edges and negative
weights are supported. There is no vertex-coordinate or raster requirement.

## Transaction contract

All transfers use one rising-edge clk and standard ready/valid. `rst` is
synchronous high, gates ready/valid low, cancels the graph and any pending
output, and resets both subcores. The DSU initializes singleton nodes in a
bounded node-by-node sweep before input opens. There is no CE or CDC. A legacy
CE-qualified stream requires a transfer adapter. Parameters are static;
there is no runtime configuration, external memory port or bus error channel.

An input beat transfers when `s_valid && s_ready`; hold all fields while
stalled. The first accepted beat supplies the opaque `s_graph_tag`, including
an excluded beat. Later graph tags are ignored. `s_keep=1` includes an edge;
`s_last=1` ends the graph even when keep is zero. One keep=0,last=1 beat represents
an empty graph. A missing last leaves the graph open until reset.

Unsigned endpoints must be in 0..NUM_NODES-1. An included edge with either
endpoint outside this range is ignored and latches `m_bad_index`. Excluded
beats do not check endpoints. Valid self-loops are silently ignored. Neither
consumes edge capacity. Eligible edges are normalized to u<v and the first
MAX_EDGES are retained. Further eligible edges latch `m_overflow` and are
drained through last. The returned forest is **of the retained prefix** when
overflow is set; it is not a result for the complete original graph. Duplicate
and parallel edges consume capacity normally. Invalid-index and overflow flags
can both be set. Graphs have at least one elaborated node; empty vertex sets
are outside the parameter contract.

After last, the heap supplies ascending `(signed weight, unsigned normalized
u, unsigned normalized v, unsigned edge_tag)` order. An edge is emitted only
when its UNION merges two different components. Selected edges therefore
appear in that deterministic order. Equal tuples are observationally identical;
there is no input-arrival stability promise. The forest is minimum by signed
weight; the remaining tuple fields deterministically break equal-weight ties.

Every output transfers on `m_valid && m_ready`. All fields stay stable under
backpressure. Output blocks new graph input. Each selected edge has
`m_summary=0` and its normalized endpoints, signed weight and original edge tag.
After all retained edges are processed, exactly one final token has
`m_summary=1`; its u/v/weight/edge_tag are zero. This token is the transaction
terminator. There is no separate LAST. It reports:

- `m_total_weight`: exact signed sum of selected weights.
- `m_selected`: selected-edge count, at most NUM_NODES-1.
- `m_components`: post-forest component count, including isolates.

These counters also report the running forest after the current selected edge
on edge tokens. Thus components=NUM_NODES-selected on every output. Graph tag
and the two settled error flags repeat on all tokens. Empty forests still
produce a summary (zero total/selected, NUM_NODES components). Fields are only
meaningful with valid. After the summary transfers, heap CLEAR and DSU CLEAR
complete before the next input is accepted. Sink stalls or missing input last
have no finite unconditional completion bound. Reset requires upstream and
downstream to restart the canceled graph.

| Parameter | Default | Legal range |
| --- | ---: | --- |
| NUM_NODES | 16 | 1..256 |
| MAX_EDGES | 32 | 1..1024 retained eligible edges |
| WEIGHT_W | 16 | 2..24, full two's-complement integer range |
| EDGE_TAG_W | 8 | 1..32 opaque unsigned bits |
| GRAPH_TAG_W | 8 | 1..32 opaque unsigned bits |

INDEX_W=max(1,clog2(NUM_NODES)); COUNT_W=max(1,clog2(NUM_NODES+1)).
TOTAL_W=WEIGHT_W+ceil(log2(max(NUM_NODES-1,1))). All sums explicitly sign-extend
the weight before adding. At most NUM_NODES-1 edges are selected, so the total
cannot overflow this width. There is no fixed-point scaling, truncation,
saturation or numeric error flag. Power-of-two node counts use all endpoint
encodings; other counts allow testing invalid IDs. Illegal public parameters
fail elaboration through a deliberately unresolved named parameter instance.
Derived localparams are internal.

## Architecture and resource review

A single heap owns the retained edge store and serializes each push/pop with
one shared comparator and synchronous memory reads. A single DSU serializes
UNION using rank trees and one read/write node store. The wrapper has one
captured edge and scalar counters; it adds no graph matrix or second edge
array. It waits for each subcore command/response, so neither has more than
one outstanding command. Capacity accounting guarantees pushes cannot be full
and pops cannot be empty; endpoint checks guarantee internal UNION is legal.
Subcore status outputs are unused under these invariants. Internal memory
corruption/fault recovery is not provided.

Default heap payload storage is 32*(16+2*4+8)=1024 logical bits; node storage
is 16*(4+3)=112 bits. At maximum parameters these are 73728 and 3072 bits.
Reset clears heap ownership and explicitly initializes DSU nodes, not a
parallel reset of every RAM entry. Mapping depends on the target. Default
qualitative resource risk is **LOW**; maximum profile has **MEDIUM** risk from
memory mapping and wide tuple comparisons. No multiplier, divider, vendor
primitive, external memory or ROM initialization is needed. Actual LUT/FF/RAM,
frequency, power and fit have not been measured.

Heap work is O(E log E), and serialized rank-only UNION work O(E log N).
Ignored/dropped input beats can transfer each clock; retained edges incur heap
push latency and block input until its response completes. Selected outputs
also serialize subsequent computation. This intentionally favors composition
and bounded storage over dense/parallel graph throughput. No cycle-rate or
continuous-stream promise is inferred from asymptotic complexity.

## Offline closure and finite evidence

Keep this package beside `../binary_heap_queue` and `../disjoint_set_union`.
`files.f` names their exact RTL dependencies; they are reused, not copied.
`examples/graph16_forest.sv` exposes the default 16-node service.

```text
python -B cores/acceleration/kruskal_msf/sim/run.py
```

The Python standard-library runner uses local OSS CAD Suite Icarus/vvp (or
IVERILOG/VVP overrides), caps every subprocess at 20 seconds, and removes
generated vectors/images with its task-specific temporary directory. It
records actual tool output and hashes for the wrapper, example, persistent TB,
runner, dependency list and both reused RTL sources in `verification.json`.
All local text is LF for committed-blob reproducibility.

Current maturity: **LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE +
HW_UNVERIFIED**. Five simulated profiles (nodes/capacity/weight/tag/graph-tag)
are 1/1/2/1/1, 3/1/8/4/4, 5/9/8/8/8, 16/32/16/8/8 and 32/64/24/32/32.
They cover 420 graphs and 3683 edge/summary tokens against an independent
Python Prim cut-expansion oracle, without heap or union-find. Cases cover
empty/singleton/disconnected graphs, cycles, all-tied weights, parallel edges,
full signed weight extrema and total sums, nonpower-of-two invalid endpoints,
masked tags, prefix overflow, seeded graphs, source gaps, held outputs and
reset cancellation during capture/push/pop/union/edge/summary. Each nonsingleton
profile exercises seven reset phases; the singleton exercises two. Graphs
reuse state without reset. The largest 256-node/1024-edge profile is compiled
only. Ten illegal parameter settings are rejected. Twenty-four tool commands
are recorded. Coverage is finite, not an arbitrary-graph or all-parameter proof.

No synthesis, place/route, STA, full regression or hardware execution was run.
Existing subcore hardware claims are not inherited by this composition.
Read-only reference and originality review: [SOURCES.md](SOURCES.md).

# Maximum cardinality bipartite matching

`bipartite_match` turns an unweighted compatibility edge stream into a maximum
cardinality assignment between a fixed left set and a fixed right set. Each
left vertex receives at most one right vertex, and each right vertex is used
at most once. This supports bounded request/resource pairing or batch
compatibility allocation. It does not attach weights, optimize costs, provide
arrival-time fairness, or update an assignment incrementally while streaming.

## Interface and result contract

All ports use one rising-edge clk. `rst` is synchronous active-high, gates
ready/valid low and cancels capture, computation and unconsumed results. After
deassertion, the adjacency matrix clears one left row per clock before input
opens. Match ownership flags reset; scratch arrays do not require reset values.
There is no CE, CDC, external memory/bus interface or runtime configuration.
A legacy CE-qualified stream needs a transfer adapter.

An input beat transfers on `s_valid && s_ready`; hold all fields while stalled.
An included beat (`s_keep=1`) declares that unsigned vertex s_left can use
unsigned resource s_right. Legal IDs are 0..LEFT_N-1 and 0..RIGHT_N-1. An
included out-of-range ID is ignored and latches bad_index for this graph.
Excluded beats do not check IDs. Left and right are distinct vertex sets, so
equal numeric IDs are ordinary edges. Duplicate edges are idempotent and have
no extra capacity cost. The fixed adjacency matrix can represent every legal
edge; there is no stream-length limit or edge-prefix truncation.

`s_last=1` ends the graph even when keep is zero. One excluded last beat
represents a graph with no edges. The first accepted beat supplies s_tag,
including an excluded beat; later tags are ignored. Missing last keeps capture
open until reset. Input can transfer every clock during capture. Computation
and output block new input, and graph contents cannot change during either.

Exactly LEFT_N output tokens transfer on `m_valid && m_ready`, in ascending
m_left order 0..LEFT_N-1. `m_matched=1` means m_right is the assigned resource;
otherwise m_right is zero and must not be interpreted as an assignment.
`m_last` marks the final left token. There is no separate summary/empty token:
an edgeless graph returns LEFT_N unmatched tokens. Each token repeats the
completed graph's maximum `m_cardinality`, captured m_tag and settled
m_bad_index. The number of matched tokens equals cardinality. All output fields
remain stable under backpressure and are meaningful only with m_valid.

After the final output transfers, ownership flags clear and the adjacency
clear sweep runs before the next input. Output tokens can transfer every clock
when ready. Arbitrary source/sink stalls have no unconditional completion-time
bound. Reset requires peers to restart the canceled graph; no partial matching
or result rollback is published.

Roots are tried in ascending left order; each alternating-path BFS uses FIFO
left-vertex order and ascending right neighbors. The first free right closes
the augmentation. This gives deterministic results for the same adjacency
matrix regardless of edge arrival order or duplicates. The chosen maximum
matching need not be lexicographically minimal. Lower roots have no promised
long-term service fairness across repeated graphs. Unmatched vertices do not
set an error: maximum cardinality may be less than either side's size.

| Parameter | Default | Legal range |
| --- | ---: | --- |
| LEFT_N | 8 | 1..32 left vertices |
| RIGHT_N | 8 | 1..32 right vertices |
| TAG_W | 8 | 1..32 opaque bits |

LEFT_W=max(1,clog2(LEFT_N)); RIGHT_W=max(1,clog2(RIGHT_N)). Cardinality uses
max(1,clog2(min(LEFT_N,RIGHT_N)+1)) bits and is exact. Nonpower-of-two counts
and count=1 expose invalid ID encodings; other powers of two use every encoding.
There is no signed/fixed-point arithmetic, rounding, saturation or numeric
overflow. Illegal public parameters fail elaboration via a deliberately
unresolved named parameter-error instance; derived localparams are internal.

## Architecture and structural review

The adjacency bit matrix stores the graph. For each currently unmatched left
root, an alternating BFS scans each reached left row, marking right vertices
once and retaining the left predecessor of each reached right. A free right
starts a backward walk: its predecessor left is rematched, and the old matched
right continues the walk until the unmatched root is reached. Each successful
augmentation increases cardinality by one. Once all roots have been processed,
there is no augmenting path and the matching has maximum cardinality.

The FIFO scratch queue holds at most LEFT_N left vertices: the seen-left bit
is set when enqueued, so no left vertex is enqueued twice in one search.
Queue pointers can represent LEFT_N without wrapping into a valid address.
Parent-right entries are read only after being written in the current BFS;
unowned match entries are never used. Augmentation samples the predecessor in
a separate read state before writing both match maps. The controller freezes
all result-dependent arrays throughout output stalls.

Alternating BFS is preferred here over parallel permutation search or a
weighted/general-graph matcher: it needs no multiplier, divider, cost matrix
or blossom structure. A small internal scratch queue shares the search's
visited/parent lifetime; existing CE/asynchronous-reset standalone FIFOs do
not remove the graph-specific state or simplify the synchronous clear policy.
No existing queue, heap, DSU, interconnect or image matcher is modified.

Array capacity is `LEFT_N*RIGHT_N + LEFT_N*RIGHT_W +
2*RIGHT_N*LEFT_W + LEFT_N*LEFT_W` bits (160 default, 1664 maximum), plus the
sampled row and four valid/seen bitmaps (40 default, 160 maximum), and scalar
control. Dynamic bit writes and small indexed scratch reads are intentional;
BRAM inference is not claimed. Qualitative resource risk is **LOW** at defaults
and **MEDIUM** at maximum from row/match selection muxes and flag decode.
No vendor primitive, external image, initialized ROM or downloaded IP is
required. Actual resources, frequency, power and device fit remain unmeasured.

Worst-case search work is O(LEFT_N^2*RIGHT_N), plus bounded path walks and row
clears. Each dequeued row has one sample clock followed by RIGHT_N serial
neighbor clocks; augmentation uses two clocks per reassigned left. Graphs do
not overlap, and there is no continuous crossbar-throughput claim. Structural
clock schedules are not measured hardware rates.

## Offline use and finite evidence

`files.f` is the complete production closure. `examples/resource_match8.sv`
exposes the default compatibility/assignment service; it is an
**INTEGRATION_CANDIDATE**, with no physical request-routing datapath implied.

```text
python -B cores/acceleration/bipartite_match/sim/run.py
```

The Python standard-library runner prefers local OSS CAD Suite Icarus/vvp,
supports IVERILOG/VVP overrides and caps every subprocess at 20 seconds.
Generated vectors and simulator images use a task-specific temporary directory
removed on exit. `verification.json` records tool output, all six source hashes
and generated-vector hashes. Local text is LF for committed-byte reproducibility.

Current maturity: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**. Twenty-seven
actual tool commands cover nine LEFT_N/RIGHT_N/TAG_W profiles:
1/1/1, 1/32/32, 32/1/1, 2/3/4, 3/3/8, 5/4/8, 8/8/8, 16/7/16 and 32/32/32.
They check 1902 graphs and 11660 assignment tokens. The maximum parameter
profile is actually simulated. Cardinality uses a generic source/sink residual
maximum-flow oracle; 868 base graphs also cross-check an independent subset
DP enumerator. All 64 possible 2x3 graphs and all 512 possible 3x3 graphs are
included, each replayed with reversed edges and duplicates. Matching-edge
membership, right uniqueness, exact cardinality, ascending left/last framing
and complete replayed assignment identity are checked separately.

Fixtures include empty/full/single-resource graphs, invalid and masked IDs,
rectangular Hall deficiencies, long alternating reroute chains, duplicate edges,
nonpower-of-two dimensions and seeded sparse/dense graphs. Hand-defined full
and long-chain results verify the specified deterministic search order. Nine
white-box reset probes per profile cover clear, partial capture, root start,
queue removal, row sample, neighbor scan, both augmentation states and held
output; these are finite phase probes, not exhaustive cancellation proofs.
Source gaps, captured-tag mutation, output stalls and reuse without reset are
covered; every graph's first valid output is deliberately held for three
clocks, including singleton profiles. Six illegal public-parameter settings
are rejected. This is finite
evidence, not an all-graph/all-parameter proof.

Synthesis, place/route, STA, full regression and hardware testing were not run.
Source provenance and the reuse decision are recorded in [SOURCES.md](SOURCES.md).

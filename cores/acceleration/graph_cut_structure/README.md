# Undirected graph cut vertices, bridges and deletion impact

`graph_cut_structure` computes the connectivity structure of an undirected
simple graph: original connected components, cut vertices, bridge edges, and
the exact global component count after deleting each vertex. This supports
link/node vulnerability analysis without a host providing a DFS tree, labels
or deletion results. It complements union-find, spanning forests and directed
flow/min-cut; those services do not identify every single-vertex/edge failure.

## Graph stream and outputs

NUM_NODES is the static vertex universe 0..N-1, including isolated vertices.
Ordinary rising-edge `s_valid && s_ready` accepts a token. A kept token assigns
presence to the unordered pair {s_u,s_v}; reversed endpoints address the same
edge. **Last assignment wins**, including s_present=0 deletion. Repetition does
not create parallel edges. Valid self-loops are ignored because they affect
none of the reported connectivity quantities. This is not a multigraph.

Both endpoints are unsigned32 and checked before narrowing, even for deletion
or self-loop offers. Any kept endpoint >=N sets the whole-frame error. Masked
tokens ignore endpoints and presence. The accepted tail closes the graph even
when masked; a masked tail alone describes an empty edge set. The first
accepted token supplies tag even when masked, later tags are ignored. There
is no retained-edge capacity or maximum update count; a missing tail waits
until input or reset, without a timeout.

Any bad index rejects the complete frame: one masked last record has error=1,
captured tag and **all numerical fields, cut flag and bridge bitmap zero**.
No prefix analysis is published. Valid input produces N kept records with
error=0, ascending node 0..N-1 and last only at node N-1:

| Field | Meaning |
|---|---|
| m_node | Vertex owning this record |
| m_component | Dense original component ID; ordered by smallest vertex |
| m_components | Global original component count C, repeated |
| m_after_removal | Global components after deleting this vertex and incident edges |
| m_degree | Number of distinct other neighbors, excluding ignored loops |
| m_cut_vertex | Exactly m_after_removal > C |
| m_bridge_neighbors | Bit j iff {m_node,j} is a bridge |
| m_bridge_count | Global number of distinct bridges, repeated |

A bridge is an edge whose deletion increases the global component count.
Each bridge is represented twice, one bit at either endpoint; sum of bitmap
populations equals twice m_bridge_count. Each bridge removal increases count
by exactly one. Deleting an isolated vertex decreases global count by one and
does not mark it as a cut. At N1 the empty graph reports C=1, after=0. Empty
edge sets are legal; empty vertex universes are outside the parameter domain.
Disconnected graphs are fully processed, without substituting a single-root
connected-graph convention. No biconnected block decomposition is returned.

All output fields and valid stay stable while `m_valid && !m_ready`. One graph
is owned until its final output transfers; new input waits through output
and a fresh full matrix clear. Hold all offered source fields stable until
acceptance. There is no final-result/next-input same-edge fallthrough.

## Clock, reset, storage and parameters

One rising-edge clock; synchronous active-high rst; no CE, CDC, runtime
configuration, external memory, generated table or vendor primitive. Reset
also gates ready/valid low while high. An active reset edge cancels input,
pending mirrored writes, DFS work, half-written bridge pairs and held normal
or error output. Public output registers clear. Memories are not reset in
parallel: the next N*N-clock sweep clears every adjacency and bridge bit
before capture, then a node sweep initializes scratch before solving. No old
entry is read first. Replay canceled work if needed. CE-qualified legacy
streams require an explicit adapter.

| Parameter | Default | Legal |
|---|---:|---|
| NUM_NODES | 16 | 1..64 |
| TAG_W | 8 | 1..32 |

Derived local widths are IW=max(1,clog2 N), CW=clog2(N+1). Node and component
IDs use IW; component counts, degrees, bridge totals and deletion counts use
CW, unsigned integers. There is no signed arithmetic, scaling, saturation,
rounding or overflow convention. Illegal settings fail elaboration through
`graph_cut_structure_invalid_parameters__see_README`.

Two separate N*N-bit synchronous memories hold adjacency and bridge presence.
A kept legal non-loop acceptance writes one directed matrix bit; MIRROR writes
its reverse on the next clock. Thus those updates have II2. Masked, invalid or
self-loop capture tokens have II1. Reads occur only after the frame is complete,
using READ then EXAMINE. Each discovered bridge writes its two directions in
different RETURN/BRIDGE_REV clocks. Output reads one bridge bit in OUT_READ
and captures it on the next clock, assembling a row bitmap. No same-clock
read/write collision or read-during-write mode is assumed for either memory.

Small indexed register arrays store discovery time, lowlink, next neighbor,
qualifying-child count, degree, parent, parent-valid and component ID. A parent
chain plus per-vertex next neighbor replaces a separate recursive call stack.
Each node is discovered once; its neighbors scan in ascending order. A back
edge lowers lowlink to the other endpoint's discovery time. Returning child v
to parent u lowers low[u], counts a separating child when low[v]>=disc[u], and
marks a bridge when low[v]>disc[u]. Parent edges are skipped only because the
graph is simple. At a non-root vertex, after=C+separating_children; at a DFS
root, after=C-1+tree_children. Every root child qualifies, including singleton
roots with zero children. This proves both articulation flags and exact impact.

All discovery/lowlink values are 1..N (zero means unseen); all cursors/counts
are 0..N. Group IDs are 0..C-1, degrees <=N-1, bridge total <=N-C, and removal
counts <=N-1. These ranges fit the stated widths, including power-of-two N.
Every neighbor/parent access derives from a checked input or initialized ID.

The memories use 2*N*N logical bits, **512** default / **8192** maximum.
Scratch arrays use `N*(5*CW+2*IW+1)` bits, **544** / **3072**, excluding scalar,
read, bitmap-assembly and output registers. Scratch is dynamically indexed
register storage, not claimed BRAM. No variable multiplication/division or
parallel edge-comparator array is present; constant row strides form addresses.
Qualitative risk is **LOW** default, **MEDIUM** at maximum due to scratch muxes
and narrow RAM mapping. Device fit, LUT/FF/BRAM, clock frequency and power are
unmeasured. No synthesis, PnR, STA or board test ran.

## Service and finite evidence

After accepted tail, a conservative first-valid observation bound is
`3*N*N+7*N+8` clocks: three clocks per neighbor, bounded root/return/bridge
steps, scratch initialization, bridge-row read and sampling margin. Error
results finish sooner. With continuous ready, subsequent results transfer
every 2*N+2 clocks. After final retirement N*N clear clocks precede ready;
the earliest next acceptance is N*N+1 periods after retirement. Arbitrary
source gaps and output stalls prevent an unconditional transaction deadline.

`python -B sim/run.py` uses standard-library Python and installed Icarus/vvp
offline, with each compiler/simulator child limited to 20 seconds. The fixed
`examples/graph_resilience16.sv` exposes all ports and adds no dependencies.
`files.f` is the complete core source list, relative to this package root.

Six finite profiles cover N1/2/4/7/16/64, tags 1..32, all 64 undirected N4
edge sets, empty/complete/path/star/cycle/disconnected graphs, loops, removals,
reverse/repeated updates, masked full-width illegal endpoints and atomic errors.
An independent oracle merges explicit Python vertex sets on the original
graph, every vertex-deleted graph, and every edge-deleted graph. It uses no
DFS, discovery times or lowlink recurrence. Every field is checked, including
component labels, exact deletion impact, symmetric bridge maps, global bridge
total and deterministic same-final-graph replay. A conservative first-valid
bound is checked, not claimed as exact latency.

Immediate reset probes cancel all 15 reachable states (two edge-specific
states are omitted at N1), plus four-clock held normal/error output with
actually blocked source. Each probe immediately asserts reset at the observed
boundary and then checks a complete fresh empty graph. This tests isolation
after partially mirrored adjacency or bridge writes. Main fixtures exclude
recovery graphs; stall counters include probes/recovery. These are finite
probes, not an arbitrary-cycle or full-domain proof. Four illegal parameter
settings must produce the named elaboration rejection. The fail-closed runner
replaces an old report with NOT_RUN before starting, then emits PASS only
after all checks and source hashes complete.

Maturity: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**, bound to source/TB/
runner/example hashes in verification.json. Example is an **INTEGRATION_CANDIDATE**
with syntax evidence only. No expanded regression or physical checks ran.
Root Apache-2.0 LICENSE/NOTICE cover the original package; actual preflight
source/license reads and absence of copied dependencies are in SOURCES.md.

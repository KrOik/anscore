# Directed dominators and all-path dependency tree

`directed_dominators` computes which vertices are unavoidable on **every**
directed path from a selected entry to each reachable vertex. It returns
complete dominator sets, immediate parents, tree depths and dominated subtrees.
This supports control/dependency analysis from raw edge assignments, without
host-provided reachability, traversal order or dominator labels. A shortest
path tree or all-pairs reachability does not identify all-path requirements;
undirected cut vertices have different orientation and root semantics.

## Graph stream and precise outputs

NUM_NODES fixes the vertex universe 0..N-1, including isolated vertices.
Ordinary rising-edge `s_valid && s_ready` accepts a token. Each kept token
sets the presence of ordered edge (s_from,s_to). Last assignment wins,
including s_present=0 deletion. Reverse edges and valid self-loops are
independent assignments. Repeats do not create parallel edges. Self-loops
do not change dominance, but still use the ordinary edge-update pipeline.

The first accepted token captures unsigned32 s_root and the tag even when
masked. Later root/tag offers are ignored. Kept unsigned32 endpoints are
checked before narrowing, including deletions. Masked tokens ignore IDs and
presence but preserve first-token ownership and accepted s_last termination.
A masked tail alone defines an edgeless graph. No update-count limit or
missing-tail timeout is imposed; an unterminated transaction waits or resets.

m_errors bit0 denotes any kept endpoint >=N, and bit1 an initial root >=N.
The bits are independent and sticky for this graph. Any error atomically
rejects the entire graph: **one masked last record**, first tag, both error
bits, and every numerical field, bitmap, reachable and parent-valid flag
zero. No prefix solution is published.

A valid graph emits N kept records, ascending m_node 0..N-1, error0 and last
only at N-1. Unreachable vertices still have records. All values are exact
unsigned integers/bitmaps with no scaling, rounding or saturation.

| Output | Meaning on a valid graph |
|---|---|
| m_root | Captured entry vertex, repeated |
| m_reachable | A path from root to this vertex exists, including zero-length root path |
| m_dominators[d] | Reachable node for which every root-to-node path contains d |
| m_idom_valid | Reachable and not root |
| m_idom | Unique closest strict dominator; zero when parent-valid=0 |
| m_depth | Number of strict dominators, or dominator-tree depth |
| m_dom_count | Number of dominators, depth+1 for reachable nodes |
| m_dominated[v] | This node dominates v, including itself if reachable |
| m_subtree_count | Population of m_dominated |
| m_reached_count | Global reachable population, repeated |

Root dominates every reachable vertex, has self-only dominators, depth0,
parent-valid0 and canonical parent0 even when root is nonzero. A reachable
nonroot node always dominates itself. Unreachable nodes have reachable0,
parent-valid0, parent/depth/counts0 and both masks0; their global reached
count and root remain valid. A valid N1 graph has both masks1, counts1,
depth0 and no parent, regardless of explicit self-loop presence. Empty
vertex universes are outside the legal domain. No dominance frontier,
postdominator, path enumeration or runtime vertex deletion is returned.

All offered source fields and valid must stay stable while blocked.
All result fields and valid stay stable while `m_valid && !m_ready`.
The graph remains owned through its final retirement and a fresh matrix
clear. No final-result/next-input same-edge fallthrough is provided.

## Clock, reset, parameters and storage

One rising-edge clock, synchronous active-high rst, no CE, CDC, runtime
configuration bank, external memory, vendor primitive or generated ROM.
Reset also gates ready/valid low while asserted. Its active edge cancels
capture, pending RMW, any reach/dominator/summary pass and held normal/error
output, clearing public registers. Then N clocks clear predecessor RAM before
capture. Dominator RAM is initialized for every node before any scan, and
every summary is overwritten before output. Read registers need no parallel
reset and are unused until a current-graph read. Canceled transactions require
replay. CE-qualified legacy streams need an explicit adapter.

| Parameter | Default | Legal |
|---|---:|---|
| NUM_NODES | 16 | 1..64 |
| TAG_W | 8 | 1..32 |

Local widths are IW=max(1,clog2 N) for vertex IDs, CW=clog2(N+1) for counts,
depths and bounded pass index. They are not public overrides. Count N and
maximum depth N-1 fit CW even at power-of-two N. Invalid public parameters
fail elaboration via `directed_dominators_invalid_parameters__see_README`.

Three synchronous memories hold N predecessor rows of N bits, N dominator
rows of N bits, and N summary rows of N+IW+2*CW bits. The predecessor row for
v contains incoming sources. A kept legal edge accepts then reads/modifies/
writes its destination row; input II3. Masked or invalid offers have II1 while
capture remains open. Reads and consumes occur on distinct clocks; no bank
depends on simultaneous read/write collision behavior.

Reachability starts at the root bit and scans predecessor rows. A nonempty
intersection with the current reached set discovers that row's vertex.
Sweeps continue until no change; at most N sweeps including confirmation.
D(root) is initialized to {root}, unreachable rows to empty, and other rows
to the reached set. For each reached nonroot vertex v, a serial synchronous
scan intersects D(p) for all **reachable** predecessors, then adds v. Source
and unreachable rows remain fixed. Sweeps continue until stable.

These sets only shrink and retain self/root. Excluding unreachable
predecessors prevents nonexistent root paths from corrupting a solution.
Any false dominator d has a root-to-v path avoiding d; it can be made simple,
with at most N-1 edges. A simultaneous predecessor sweep propagates that
exclusion by at least one edge. In-place sweeps cannot converge slower, so
N sweeps including a no-change confirmation suffice. Reachability has the
corresponding simple-path bound. No unbounded input-dependent recursion or
external traversal stack is used.

Strict dominators of one reached node form an ancestor chain. The summary
scan starts a candidate at root; a strict ancestor j replaces it exactly when
the candidate dominates j. This retains the deepest strict ancestor regardless
of numeric vertex order. The scan also counts strict ancestors and checks each
dominator row's column to build the complete dominated subtree. Distinct
summary/write/output-read states ensure final counts and parents settle before
publication, including the last node and a nonzero root.

Logical RAM is `3*N*N + N*IW + 2*N*CW`: **992** default / **13,568** maximum
bits. Scalar/read/output declarations total `17+10*N+12*IW+10*CW+2*TAG_W`:
**291** / **863** bits. The combinational input-update temporary is excluded
from stored bits. There are no scratch register arrays, variable multipliers,
dividers, parallel all-vertex combinational matrix iterations or hidden sibling
sources. Qualitative risk is **LOW** default / **MEDIUM** maximum due to row
selectors, wide bitwise intersections and small-memory mapping. These logical
counts are not measured LUT/FF/BRAM, Fmax, power or device-fit results.

After accepted tail, a conservative first-valid observation bound is
`2*N*N*N+7*N*N+6*N+12` periods. It includes pending input RMW, at most N reach
sweeps, full dominator initialization, at most N predecessor-intersection
sweeps, complete summary scans, first replay read/load and sampling margin.
Error results appear earlier. With continuous ready, subsequent outputs
transfer every3 periods. After final retirement N clear writes precede ready;
earliest next acceptance is N+1 periods later. Source gaps and sink stalls
preclude an unconditional whole-transaction deadline.

## Offline example and finite evidence

files.f lists only rtl/directed_dominators.sv. The fixed default wrapper
examples/dependency_gate16.sv exposes every port and adds no dependencies.
`python -B sim/run.py` uses standard-library Python and installed Icarus/vvp
offline. TEST_PLAN.json freezes six profiles before the first tool run:
N1/2/3/7/16/64 with tag widths1..32; every directed N<=3 matrix for every
root, including all1536 rooted N3 graphs. Larger profiles cover directed
families, nonzero roots, unreachable components, cycles/loops, removals,
host-width masked IDs, atomic errors and deterministic reordered replay.
The maximum profile has eight predefined main graphs and full reset probes.

The independent oracle deletes each possible candidate vertex and runs BFS
from root. A vertex dominates v exactly when initially reachable v becomes
unreachable after deletion, including deletion of itself/root. This computes
the all-path definition without predecessor-set intersection or fixed-point
sweeps. Immediate-parent chains crosscheck the resulting sets. Every output
bit/count/flag and conservative first-valid bound is checked.

Immediate probes cancel all23 FSM states (three nonroot update states are
unreachable at N1), four-clock held good/error output with a genuinely blocked
source, a middle reach row, a middle predecessor merge and a middle summary
scan. The unreachable middle merge is also omitted at N1:164 cancellations
overall. No extra active edge precedes reset assertion after the target is
observed. Every probe is followed by a complete fresh forward chain, checking
all nodes' ancestor/subtree masks, exact parents/depth/counts and first tag;
N1 uses an explicit self-loop. Recovery exercises RMW, reach, domination,
summaries and output rather than returning only an empty status.

Every main record is held at least four clocks. Assertions check complete
source/output stability, descending dominator sets, root/self retention and
at-most-N convergence. Probe/recovery counters are separate from main frame
and output totals; stall/write/pass maxima include both. Four invalid
parameters must produce the named rejection. Every compiler/simulator child
has a20-second limit; timeout stops and records TIMEOUT_NOT_RUN with no
reduced fixtures, increased limit or retry. The runner writes NOT_RUN and
source hashes before tools, saving every completed record. Ordinary failures
are retained separately on a corrected rerun; they are never qualified PASS.

Current maturity and measured finite totals are in verification.json, bound
to all non-report files. **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED** applies
only to the completed stated matrix; it is not a full-domain proof. The
example is an **INTEGRATION_CANDIDATE** with syntax evidence. No synthesis,
PnR, STA, board test or expanded regression runs. Root Apache-2.0 LICENSE
and NOTICE cover this original package; actual fixed-source/full-license
preflight and semantic deduplication are recorded in SOURCES.md.

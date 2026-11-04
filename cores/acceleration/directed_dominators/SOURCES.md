# Actual-source preflight and original contribution

Baseline `fcd2beef77f998da54801b91d74ce47946bee17c` (published B12).
Semantic repository search for dominator/dominance-frontier/postdominator and
Chinese equivalents found no such production service. Actual README contracts
were read for directed_reachability (existence of paths and SCC), dijkstra_sssp
(nonnegative shortest distances and one shortest predecessor tree), and
graph_cut_structure (undirected vertex/edge vulnerability). None computes
vertices required by every directed entry-to-node path. Other dominance search
matches concern optimization metrics, not graph dominators. No existing
interface or old source is modified.

Before RTL authoring, actual NetworkX3.4.2 source at immutable commit
`2acf1590f82757c01a57b81b8c5dfb79e60aa416` and the complete BSD3 license were
read using GitHub contents API with a15-second request timeout. The entire
3450-byte module was inspected, including immediate_dominators and
dominance_frontiers, plus all1763 license bytes.

| File | Git blob | SHA256 |
|---|---|---|
| [networkx/algorithms/dominance.py](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/networkx/algorithms/dominance.py) | 30cb8115c3ad6924a523f015ea2161417d401679 | 4ffcf7ee3c7f5926d8fc731f620a992fa7d3fa9e8f3009598d2c0456c68b7cb1 |
| [LICENSE.txt](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/LICENSE.txt) | 100b4bffb00abd785f61fca42fea2ab74a70d7f7 | 5b433b90f755eb9bbd06feff1d1a4f5f232c5208a185694199e45fa95d762792 |

The complete BSD3 notice names NetworkX Developers2004–2024 and
Hagberg/Schult/Swart. Redistribution requires notice/conditions/disclaimer,
binary documentation retention and non-endorsement; warranties and liability
are disclaimed. It was a feasibility/reference inspection, not local reuse.

Upstream immediate_dominators uses DFS postorder numbering and an intersect
walk up currently known parents, returning start's parent as itself. Its
dominance_frontiers walks parent chains from multi-predecessor joins. This
local implementation independently uses predecessor row RAM, reached-bitset
sweeps, descending dominator-set intersections and serial summary scans. It
returns all static vertices, canonical invalid parent0 on root/unreachables,
and full ancestor/subtree masks. No upstream API, frontier result, numerical
iteration sequence or test-coverage compatibility is claimed.

The web tool failed HTTP500 (`channel does not support /v1/alpha/search`).
Two fixed raw-content curl reads each stopped at15 seconds without receiving
source; they were not treated as successful preflight. The fixed contents API
then returned both actual files and blob IDs above. These were untrusted text
in process memory: no module import, installer, script or build was run.
No upstream implementation, prose, comments or tests were copied, translated,
adapted, persisted or redistributed. RTL, wrapper, testbench, deletion/BFS
oracle, runner and documentation are original Apache-2.0 repository work.

Offline closure contains one authored production RTL and one optional fixed
wrapper. No generated table, external memory asset, online build, third-party
Python package, vendor library or sibling/untracked RTL is required. Root
LICENSE/NOTICE supply the applicable contribution license. Parameter bounds,
qualitative resource risk and exact finite evidence scope are local contracts;
no synthesis, PnR, STA or hardware qualification is implied by preflight.

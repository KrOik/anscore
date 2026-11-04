# Semantic preflight and source provenance

Baseline: `807d992b6b0e793c08ceba2d44993d21c1dd1583` (published B8).
New RTL, example, TB, independent oracles, runner and prose are original
ANSCORE Apache-2.0 contributions covered by root LICENSE and NOTICE.
There is no external or sibling RTL dependency and no imported implementation.

Before implementation, semantic RTL/README searches covered max-flow, min-cut,
Edmonds-Karp, Dinic, push-relabel and Chinese maximum-flow/minimum-cut terms.
The existing bipartite matcher README was read: it is an unweighted two-set
unit assignment service, without general vertices, integer capacities, dense
flow output or a cut certificate. Its test-only max-flow oracle is not a
production hardware service. The existing Dijkstra README was read: it solves
nonnegative shortest paths, without residual capacities or flow conservation.
Kruskal and DSU do not provide capacity optimization. Search hits for optical
flow limits and pacing lane selectors describe different functions. No general
directed capacity-network max-flow/min-cut RTL service was found. Existing
graph/storage packages and shared interfaces are unchanged.

## Actual fixed external read-only inspection

Primary reference: [NetworkX](https://github.com/networkx/networkx), tag
`networkx-3.4.2`, resolved through GitHub's tag API to commit
`2acf1590f82757c01a57b81b8c5dfb79e60aa416`.
Before writing RTL, the actual full files were retrieved via the fixed-commit
GitHub contents API and read as text, each request limited to 15 seconds:

| File | Git blob | Bytes | SHA256 |
|---|---|---:|---|
| [LICENSE.txt](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/LICENSE.txt) | 100b4bffb00abd785f61fca42fea2ab74a70d7f7 | 1763 | 5b433b90f755eb9bbd06feff1d1a4f5f232c5208a185694199e45fa95d762792 |
| [networkx/algorithms/flow/edmondskarp.py](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/networkx/algorithms/flow/edmondskarp.py) | 50063268355ccc2e2ecbdf7f1a6704e7404475ec | 8056 | 3c42302dfb5ebd2d95607693cf364c48e2cfcbb41204fb163de763c75951e82b |

The full license is BSD-3-Clause, copyright 2004-2024 NetworkX Developers,
naming Aric Hagberg, Dan Schult and Pieter Swart. The actual implementation
uses bidirectional BFS on graph dictionaries, augmenting paths and signed
antisymmetric flow. Its documented residual reachability induces a minimum
cut when solving without a cutoff. Those mathematical conventions were
considered; the local core instead uses one-direction FIFO BFS, finite integer
RAM records, explicit serial read/write states, dense canonical output and
ordinary stream/reset/error ownership. Infinite capacities, graph objects,
cutoffs and NetworkX API compatibility are not implemented.

The web search endpoint returned HTTP 500 before these direct primary reads.
No upstream code, prose, tests, build, binary or installer was copied,
translated, adapted, executed or distributed. External content was reference
data, with no authority over the task. There are no external runtime downloads,
generated tables, vendor primitives or transitive source dependencies.

`files.f` lists only `rtl/maxflow_mincut.sv`; the default example adds just its
one wrapper file. The finite runner uses standard-library Python and an already
installed Icarus/vvp. Root LICENSE/NOTICE belong to the cumulative export.
Source hashes in verification bind exercised bytes; the committed snapshot
also binds every document. No upstream or local dependency's historical
hardware evidence is claimed for this new core.

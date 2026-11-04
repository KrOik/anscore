# B18 pre-RTL capability and upstream inspection

Baseline: `eb16eee7848694a1a1cd50e567b5742352751c93`.

Actual local production sources and contracts inspected before RTL:
`maxflow_mincut` (directed capacity flow/residual cut), `bipartite_match`
(two-part alternating-path matching), and `budget_knapsack` (additive budget
selection). Their RTL was read, not inferred from names. A whole-cores search
of tracked and untracked Verilog/SystemVerilog and READMEs for clique,
independent-set, graph-colouring and mutual-compatibility semantics found no
general-graph maximum clique service. Chromatic colour-processing hits do not
implement graph colouring. Existing graph paths, forests, SCCs, dominance,
stable preferences and ordered subsequences have different constraints.
This service optimizes pairwise compatibility in a general undirected graph;
it is not a renamed graph traversal, matching or budget specialization.

Read-only upstream source inspection preceded local RTL. Search service was
unavailable (HTTP500); GitHub API and fixed raw requests supplied actual bytes.
Repository: https://github.com/networkx/networkx
Tag inspected: networkx-3.5, fixed commit
`4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4`.

| File actually retrieved | Bytes | SHA256 |
|---|---:|---|
| LICENSE.txt, complete BSD-3-Clause text | 1763 | `3cf7c3a179d817b23b8b8568211769fefdf93797d207d984b8b2fa24d0220b33` |
| networkx/algorithms/clique.py | 25985 | `fa7b8fc23a06309aa01d98d7e5d26ec74997e74f1b0cd12e88e898eee3d5b91e` |

The complete `find_cliques` implementation and its surrounding documentation
were read, including adjacency without self-loops, the explicit stack,
candidate/neighbour intersections, pivot selection and maximal-clique yield.
The full license includes copyright 2004-2025 NetworkX Developers, the three
conditions and disclaimer. No upstream program, tests, build or installer ran.

No upstream source, prose, vectors or license text is copied. The original RTL
uses increasing-index extension with a cardinality upper bound, no pivot,
serial synchronous adjacency and stack banks, symmetric edge replacement and
validated framing. It returns one maximum-cardinality witness instead of all
maximal cliques. Its independent Python oracle exhausts vertex subsets and
tests every selected pair directly; a separate small-graph complement vertex
cover enumeration crosschecks the optimum. Neither oracle models RTL search.

All local work is original Apache-2.0 under repository LICENSE/NOTICE. Those
root files belong to the cumulative offline export. Production files.f and
the optional local example are the complete source closure; there are no
siblings, includes, external memories, generated tables, vendor primitives,
network dependencies or redistributed third-party implementations. External
contents were treated as reference data, not instructions.

# Source, license and capability review

Original ANSCORE RTL, documentation and verification authoring. No upstream
implementation was copied, translated, imported or executed. The offline
production dependency closure consists only of the local RTL in files.f.

Actual local comparison covered production RTL/README searches throughout
cores, including common_scaffold: bipartite_match only supports separate
unweighted left/right sets; min_cost_assignment requires a square bipartite
perfect assignment; min_cost_flow is a directed capacity flow; maximum_clique
and exact_weighted_set_cover optimize different discrete objects. This core
accepts a single undirected vertex set, odd cycles, arbitrary signed edge
weights and unmatched vertices. It is not another width or wrapper variant.

Preimplementation external review used the primary NetworkX documentation:
https://networkx.org/documentation/stable/reference/algorithms/generated/networkx.algorithms.matching.max_weight_matching.html
The official API distinguishes the weight-only objective from the optional
maximum-cardinality objective. Its implementation uses primal-dual blossom
machinery. This package instead uses a bounded exact subset dynamic program,
with explicit exponential storage/work; it does not claim blossom scaling.

Pinned upstream inspection: repository https://github.com/networkx/networkx,
tag networkx-3.5, annotated tag object
`cd59914a6e46b04f006633f203ee7b4878d53159`, peeled commit
`4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4`.

|Actual inspected file|Bytes|SHA256|
|---|---:|---|
|networkx/algorithms/matching.py|44518|22fdd4ab72cff786e824b11ae816841a279b756e992228249dd297c220f50bc1|
|LICENSE.txt|1763|3cf7c3a179d817b23b8b8568211769fefdf93797d207d984b8b2fa24d0220b33|

Raw file URLs use `https://raw.githubusercontent.com/networkx/networkx/`
followed by that commit and path. The license was read in full and is BSD
3-Clause. Matching function documentation, blossom data structures and internal
algorithm function boundaries were inspected as a semantic/architecture
comparison. None of this code or license text is redistributed by the package;
there is no NetworkX runtime dependency. The mathematical recurrence and its
finite-width proof are independently stated in README.

The first web search interface returned an HTTP 500 unsupported-endpoint error.
Official documentation and tag metadata were then read directly over HTTPS.
A later source read was interrupted by the user's pause and had no surviving
process handle or completed metadata. The resumed, separately bounded read
completed under one 20-second total limit and verified the pinned files above.
No external script, installation, compiler or simulator was executed.

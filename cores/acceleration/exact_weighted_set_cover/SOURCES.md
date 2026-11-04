# Provenance and semantic boundary

Original local RTL, example, TB and standard-library runner; Apache-2.0 under
repository LICENSE/NOTICE. No external source was copied, imported, executed
or saved as a local build input. Production dependency closure is files.f.

Before writing RTL, root resolved google/or-tools v9.14 to the actual Git
commit `0d60e8afe450ec817f510aae965ab8898310cb41` using git ls-remote and the
GitHub Git-commit API. Root read both complete files over read-only HTTPS:

| Fixed upstream path | Bytes | SHA256 |
|---|---:|---|
| examples/contrib/set_covering3.py |3572|600cad70ce0048ba25ad7b27912c4b846d79f3b4b99cc665d975cff09640e13b|
| LICENSE |11358|cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30|

Repository: https://github.com/google/or-tools . Source reference:
https://github.com/google/or-tools/blob/0d60e8afe450ec817f510aae965ab8898310cb41/examples/contrib/set_covering3.py .
The example copyright is Hakan Kjellerstrand2010 and license Apache-2.0.
The full repository license was inspected before implementation. The upstream
models unweighted group coverage with CP Solver; it provides a conceptual
constraint reference only. Local design independently adds runtime unsigned
weights/target, exact bitmap tie, finite bounded synchronous-memory service,
framing/error/reset/backpressure and an offline independent oracle. There are
no linked upstream dependencies or modified external files to distribute.

Actual semantic dedup searched production RTL and contracts throughout cores
(including cores/system/common_scaffold), docs and README using precise set
cover/setcover/hitting set/exact cover/Chinese coverage terms. There was no
matching coverage-selection implementation. An earlier broad regex also
matched reset-coverage prose and was rejected as insufficient evidence.
Root read budget_knapsack README and relevant RTL: it maximizes additive value
under scalar capacity, without arbitrary column-cover constraints. Root read
maximum_clique full contract and the preceding exact_graph_coloring package
architecture/tests: they solve pairwise adjacency and coloring respectively.
This service changes feasibility/optimization and returns a coverage witness;
it is not a renamed width, graph, constant or item-count variant. Ordinary
stream masks/bitmaps/coverage monitors do not solve minimum-weight set cover.

Architectural alternatives were considered before RTL: recomputing every
subset would require R reads per subset; universe-indexed DP may require2^U
storage at U32. Bounded DFS instead uses R stack records, one row read per
branch and explicit exponential latency. The test oracle deliberately uses
coverage-state DP for algorithmic independence. Physical implementation,
frequency, power, BRAM mapping and throughput remain unmeasured.

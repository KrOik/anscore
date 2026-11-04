# Provenance and preimplementation review

Baseline: `d35ce742b34ffa7afebffe0b9f6705a825f469e1`.
Original ANSCORE implementation under repository Apache-2.0 LICENSE/NOTICE.
No third-party source is copied, translated, vendored, imported or executed;
there are no third-party runtime dependencies or external generators.

Before RTL authoring, semantic repository searches and actual contract reads
covered `dijkstra_sssp` (weighted single-source route/distance),
`graph_cut_structure` (undirected articulation/bridge/deletion impact),
disjoint-set/Kruskal and flow/min-cut packages. None supplies directed
reflexive all-pairs closure plus SCC membership and explicit positive-cycle
semantics. Camera SCCB name matches are unrelated. The new service is not a
renamed width variant of an existing package.

The web tool returned HTTP500 (`channel does not support /v1/alpha/search`).
Read-only fixed GitHub contents API requests then retrieved and inspected
actual NetworkX3.4.2 source and the complete BSD3 license before authoring.
Responses were treated as untrusted data. Python AST parsing selected whole
function texts for reading; no fetched module, installer or build was run.

Repository: https://github.com/networkx/networkx
Fixed commit: `2acf1590f82757c01a57b81b8c5dfb79e60aa416`.

| Actual file | Bytes | Git blob | SHA256 |
|---|---:|---|---|
| LICENSE.txt | 1763 | 100b4bffb00abd785f61fca42fea2ab74a70d7f7 | 5b433b90f755eb9bbd06feff1d1a4f5f232c5208a185694199e45fa95d762792 |
| networkx/algorithms/dag.py | 45070 | c757afb96f1398d64ae63a5f682e46031a38ff8d | cb61e1666d3ea2545969b828f717338ec59ff0e6d2786fbe5499773c8121f5c1 |
| networkx/algorithms/components/strongly_connected.py | 9542 | 393728ffe1f25a077aee6691fe913a81570ef0f1 | 8b8d6f0de6b374d1aa1b8c1eb9f00a77a6b168dda704a98ccd445906ced6b0b2 |

The complete BSD3 notice identifies NetworkX Developers2004–2024 and
Hagberg/Schult/Swart, permits source/binary redistribution subject to notice,
disclaimer and non-endorsement conditions, and disclaims warranties/liability.
This was a license feasibility preflight, not evidence of local code reuse.

Actual full `descendants` and `transitive_closure` bodies were inspected in
[dag.py](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/networkx/algorithms/dag.py).
The former uses graph BFS; the latter exposes reflexive/nontrivial/omitted
diagonal modes. Actual `strongly_connected_components` and `condensation`
bodies were inspected in
[strongly_connected.py](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/networkx/algorithms/components/strongly_connected.py).
They use Tarjan/Nuutila graph iterators/dictionaries and component mappings.
The local implementation independently uses synchronous row-RAM Warshall,
then mutual reach scans, minimum-vertex labels and a held stream interface.
It does not claim upstream API compatibility, dense condensation IDs or
NetworkX test coverage. The independent finite test oracle is also local.

Offline dependency closure: files.f contains only rtl/directed_reachability.sv;
the fixed example adds no other module. README and verification.json state
precise finite scope and HW_UNVERIFIED status. No internet access is needed
to instantiate or run the supplied checks with installed tools.

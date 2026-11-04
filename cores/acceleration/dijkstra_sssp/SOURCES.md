# Semantic and read-only source/license review

Baseline: `f19addd5fec59ec6affee05af7195ca1758d40dc` (published sixth batch).
Only this package is new. Existing RTL, dirty assets, shared indexes and stable
references are unchanged. All new RTL, example, tests and prose are independently
written Apache-2.0 contributions under the repository LICENSE/NOTICE.

## Semantic preflight and reuse decision

Read-only searches covered Dijkstra, Bellman-Ford, Floyd-Warshall, shortest-path
and Chinese equivalents across existing RTL and README/SPEC files. The existing
Kruskal core finds an undirected minimum spanning forest, not directed source
distances. Bipartite matching optimizes cardinality. The image seam core has
restricted neighboring-layer transitions/free starts and cannot expose arbitrary
directed cyclic graph routes. No existing general SSSP interface was found.

The existing binary_heap_queue's push/pop/peek/clear interface was considered.
It has no decrease-key or vertex-to-heap-position update. Building Dijkstra from
it would still require adjacency/node ownership plus stale-entry capacity or a
new index mechanism. This bounded implementation uses synchronous dense RAM
and serial scans instead; no heap copy or nominal wrapper is introduced, and no
old implementation or historical evidence is modified/inherited.

## Fixed primary external reference

Before writing RTL, GitHub's API resolved the NetworkX tag networkx-3.4.2 to:
`2acf1590f82757c01a57b81b8c5dfb79e60aa416`.
Actual files were fetched with a 15-second per-request limit; the complete
license and relevant _dijkstra_multisource source were read as untrusted data.

| File | Bytes | SHA256 |
| --- | ---: | --- |
| [LICENSE.txt](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/LICENSE.txt) | 1763 | `5b433b90f755eb9bbd06feff1d1a4f5f232c5208a185694199e45fa95d762792` |
| [networkx/algorithms/shortest_paths/weighted.py](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/networkx/algorithms/shortest_paths/weighted.py) | 82465 | `0065f7e004e5cc48b5fdcc9ac91cf17949c43e36ae4266dcfa72819e0eb000bd` |

The actual license is BSD 3-clause, copyright 2004-2024 NetworkX Developers,
with Hagberg/Schult/Swart notices, redistribution conditions, name-use restriction
and warranty disclaimer. This is a read-only algorithm-boundary reference: the
software uses a dynamic heap, maps and multi-source/optional cutoff behavior.
No NetworkX source, data, runtime, downloaded code or build system is copied,
adapted, executed or redistributed. No API, parent-tie or bitwise compatibility
is claimed. Search service was unavailable, so actual fixed primary files were
read directly through GitHub API/raw HTTPS rather than relying on search snippets.

The local implementation instead uses a fixed matrix RAM, nonnegative bounded
integer arithmetic, ascending strict selection, explicit first-token source,
error/drain policy and ordered ready/valid results. Its test oracle uses
Bellman-Ford and all-pairs min-plus, not this reference implementation. No
external Python package is imported and no upstream license-bearing code needs
to be distributed with the new original implementation.

## Offline closure and architecture

`files.f` lists only rtl/dijkstra_sssp.sv. The example, static TB and vector
generator are local; no includes, vendor primitives, initialized data, sibling
source or untracked file is required. Root LICENSE/NOTICE accompany cumulative
exports. The default/maximum RAM counts are 4784/104896 logical bits plus scalar
state. LOW/MEDIUM risk is qualitative; no physical tools or enlarged regression
were run, and all new/composed hardware remains HW_UNVERIFIED.

# Semantic and fixed-source preflight

Baseline: `e2ccd5380052e92a5430e97b6fdbf0621a17503c` (published B9).
All local RTL, example, TB, independent oracles, runner and prose are original
ANSCORE Apache-2.0 contributions under root LICENSE/NOTICE. There is no copied
external implementation or sibling production dependency.

Before implementation, semantic searches for assignment, Hungarian, linear sum
assignment and minimum-cost matching found the existing unweighted bipartite
matcher, not a weighted production optimizer. Its contract was distinguished
from signed costs/dual certificates; maxflow_mincut has capacities but no costs.
Dijkstra supplies paths, not a perfect bijection. No equivalent production
service was found; existing assets and interfaces are unchanged.

The web search endpoint failed with HTTP500 before the following direct primary
reads. The actual complete files were retrieved through fixed GitHub contents
API requests and read before writing RTL, not inferred from names or snippets:

SciPy v1.15.2 commit `0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`.

| File | Git blob | Bytes | SHA256 |
|---|---|---:|---|
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | 117117616e806a9bb960b1f32a552c8c912b0497 | 1536 | c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173 |
| [rectangular_lsap.cpp](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/optimize/rectangular_lsap/rectangular_lsap.cpp) | 8b9157e328158465346c10d5e8db7892ae1fc8b7 | 7837 | 73d78155990732311a116bc04f7f64d874c0f3793172e9aab12a476cb3d15c2c |

The full root license is BSD-3-Clause, naming Enthought and SciPy Developers;
the actual source also contains its full BSD3 header. The implementation names
PM Larsen and Crouse's 2016 rectangular assignment work. Its floating-point
rectangular shortest-augmenting-path algorithm, dual update and infeasibility
handling were inspected. The local standard serial integer Hungarian algorithm
instead supplies a square sparse streamed matrix, finite slack-valid bits,
synchronous RAM, exact integer widths, explicit error/reset ownership and dual
or Hall certificates. No SciPy API or bit compatibility is claimed.

No upstream source, prose, tests, executable, build or installer was copied,
translated, adapted, executed or redistributed. The reference was read-only
data and had no authority over task instructions. There are no runtime downloads,
generated external tables, licensed vendor primitives or transitive imports.
`files.f` lists one local RTL file; the example adds one local wrapper.
Only standard-library Python and installed Icarus/vvp run finite tests offline.
The report binds exercised source bytes, and the committed snapshot additionally
binds documents and root license support. No prior hardware evidence is inherited.

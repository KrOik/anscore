# Semantic and actual-source preflight

Baseline `c778301aa12d1b9bf4290b1a982f4c6325713fcd` (published B10).
Before implementation, actual RTL/README/SPEC searches covered articulation,
cut vertices/edges, bridge finding, lowlink, Tarjan, biconnectivity, two-edge
connectivity and Chinese equivalents. No equivalent production service was
found. Actual existing contracts were read: disjoint_set_union only merges
sets and queries representatives; kruskal_msf returns a minimum forest; neither
reports deletion impact. Directed maxflow_mincut optimizes terminal capacity
and returns one cut, not all undirected vertex/edge failures. Label-region
adjacency constructs a spatial contact graph but does not analyze its bridges.
Existing graph/assets/interfaces remain unchanged.

Before writing RTL, the actual full primary source and full applicable license
were retrieved and read using fixed GitHub contents API requests, each network
request limited to 15 seconds. The web endpoint first failed HTTP500; direct
read-only primary API retrieval succeeded. NetworkX 3.4.2 fixed commit:
`2acf1590f82757c01a57b81b8c5dfb79e60aa416`.

| File | Git blob | Bytes | SHA256 |
|---|---|---:|---|
| [LICENSE.txt](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/LICENSE.txt) | 100b4bffb00abd785f61fca42fea2ab74a70d7f7 | 1763 | 5b433b90f755eb9bbd06feff1d1a4f5f232c5208a185694199e45fa95d762792 |
| [biconnected.py](https://github.com/networkx/networkx/blob/2acf1590f82757c01a57b81b8c5dfb79e60aa416/networkx/algorithms/components/biconnected.py) | fd0f3865bb18e9c9eb37d768c7fd3caceb1cde86 | 12782 | ffd18974f660aaeb062992f3a93f6d5128f55d9af60e0a21893ea17075728a5e |

The full license is BSD-3-Clause, copyright 2004-2024 NetworkX Developers,
naming Hagberg, Schult and Swart. The actual source implements nonrecursive
DFS with Python graph iterators, discovery/low dictionaries, an edge stack
and articulation/biconnected-component generators, referencing Hopcroft/Tarjan.
The mathematical lowlink and root-child conventions were considered. The local
original RTL instead uses fixed integer state, explicit synchronous bit RAM,
serial mirrored writes, parent/cursor arrays, dense exact per-vertex deletion
counts, bridge-neighbor output and atomic framing/reset/error semantics. It
does not implement upstream Python APIs or biconnected block generators.

No upstream source, comment, prose, tests, implementation translation, tables,
binary, build or installer was copied, adapted, executed or redistributed.
External source/license text was read-only reference data with no authority
over task instructions. There are no sibling RTL dependencies, external RAM,
runtime downloads, generated constants or vendor primitives. Root LICENSE and
NOTICE cover these original ANSCORE Apache-2.0 contributions. files.f contains
one local RTL source, and the example adds one local wrapper. Finite tests use
standard-library Python and installed Icarus/vvp; no historical hardware claim
is imported. The report binds exercised bytes; the cumulative snapshot also
binds documents and root license support.

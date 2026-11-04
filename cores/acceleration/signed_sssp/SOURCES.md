# Pre-RTL inspection and independent implementation

Baseline `c4be2839103480e23976f16f8a41d06fd93057c8`, 2026-11-05.

Actual fixed source and full license read using read-only HTTPS GitHub contents
API before local RTL; search endpoint returned HTTP500. No downloaded code was
executed, imported, persisted or used as build tooling.

- Repository https://github.com/TheAlgorithms/Python
- Commit `574d100b7181956e9c8384552fd078165e4cc326`
- `graphs/bellman_ford.py`, 2320 bytes,
  blob `da8526f08827fdc9210215208d9ee3d8dc648111`, SHA256
  `fb0d9faf24c5d34f0ca7ac6fd1e6f9962708b1dc865f816c894c311e0ba52176`.
- Full `LICENSE.md`, 1095 bytes, MIT, copyright 2016-2022 TheAlgorithms and
  contributors; blob `de631c3ef33374d91a78dca3a656806e4e3bb890`, SHA256
  `4395a1dc4bda1d6054c45b4d1230c709c7398e6d66f1d0aff4b22d95973bea56`.

Actual upstream performs in-place N-1 edge relaxations and throws an exception
when another reachable improvement exists. It does not identify downstream
negative-infinite vertices or preserve unaffected finite results. Local RTL is
independently authored Apache-2.0: double-bank synchronous length-bounded
relaxation, explicit reachable bits, Nth-pass seed flags, reachability closure
of those flags, last-assignment graph updates, full-ID checks, atomic invalid
frame response, ordinary ready/valid and reset/held ownership. No API or float
bit equivalence is promised. No upstream source is copied into production.

## Complete inspected reference license

Copyright (c) 2016-2022 TheAlgorithms and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Semantic deduplication

Actual `dijkstra_sssp` contract limits edges to nonnegative unsigned weights;
its parent/settlement structure cannot classify reachable negative cycles.
`directed_reachability` has unweighted reach/SCC/cycle facts but cannot determine
cycle total weight or finite signed distance. `min_cost_assignment` uses a
bounded assignment cost matrix; its Bellman-Ford mention belongs to its test
oracle, not a reusable signed graph service. Global production RTL/README
search found no other Bellman-Ford/negative-cycle/negative-infinity service.
The existing graph assets remain byte-identical. This package has one local
production source and a directly connectable example, no sibling dependency,
ROM/init file, external memory or vendor primitive. Root LICENSE/NOTICE apply.

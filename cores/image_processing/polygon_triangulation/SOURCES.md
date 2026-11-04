# Semantic and license preflight

Baseline `1fcf2f92dbf763e3251bd2994a7b9fd940c43694` is the published B21 tree.
Before writing RTL the complete cores tree was searched for triangulation,
earcut, ear clipping, tessellation, polygon/triangle conversion and Chinese
equivalents. No production implementation was found. Actual contracts read:
`point_convex_hull`, `polygon_raster_mask`, `polyline_rdp`, common_scaffold
`contours`, `geometry`, `seam_find`, `filters`, and `moments`. Raster-mask ports
were also read. Hull produces an envelope, contours ordered cell edges, RDP
approximates a polyline, and raster-mask does parity filling; none decomposes a
concave polygon into triangles. Existing seam finding and full grayscale
reconstruction were identified and rejected as duplicate candidate directions.

Complete untrusted upstream files were fetched into memory and read before
RTL, without importing, running, adapting or copying implementation code:

- Repository: https://github.com/mapbox/earcut ; version v3.0.2.
- Annotated tag `d128042b4a6d63fc20e8bbd066132b3a77a1075d` peeled through
  the GitHub git/tags API to `1b942f01f4093afe8f9ba729c3850b229f69eb12`.
- [src/earcut.js](https://github.com/mapbox/earcut/blob/1b942f01f4093afe8f9ba729c3850b229f69eb12/src/earcut.js),
  all 682 lines / 21256 bytes; SHA256
  `83d5b59bc520601bb2dd7401a2f8382a008d8d95e0e6e0fe45759ae4fda1aa56`.
- [LICENSE](https://github.com/mapbox/earcut/blob/1b942f01f4093afe8f9ba729c3850b229f69eb12/LICENSE),
  complete 738 bytes; SHA256
  `324139c19d87af03fda38afea1590e00ca354c4159bdb2ae9e9cec070cfa46a8`.
  ISC, Copyright (c) 2024 Mapbox. The complete permission and warranty clauses
  were read. package.json was also read in full (1012 bytes, SHA256
  `5f529af5e7fae81c5b745fe9e00cedf52cd04ff83f03ad4e37bb5c75fee6c337`).

Upstream is a floating-point, linked-list, hole-capable algorithm with hashing
and self-intersection repair. It supplies semantic background only. Local RTL
is an original bounded exact-integer serial engine, rejects invalid rings, and
uses a different deterministic selection order. Its reference uses exact
Fraction visibility/interval triangulation and full mesh certificates. There
is no upstream runtime, JavaScript, dependency or bit-compatibility claim.
All delivered original code is Apache-2.0 under the root LICENSE/NOTICE.

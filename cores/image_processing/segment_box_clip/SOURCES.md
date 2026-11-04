# Semantic review and read-only source/license preflight

Baseline: `f19addd5fec59ec6affee05af7195ca1758d40dc` (published sixth batch).
Only this new package directory is written. Stable references, existing sources,
untracked assets and shared indexes are untouched. All local RTL, testbench,
vector generator, example and documentation are independent Apache-2.0 work.

Actual source and full license were inspected read-only via GitHub contents API
before writing RTL. Boost.Geometry tag boost-1.86.0 resolves to immutable commit
`f82eb32da79641697583a43be9988d7517d8553c`:

| File | Git blob | SHA-256 |
|---|---|---|
| [include/boost/geometry/algorithms/detail/overlay/clip_linestring.hpp](https://github.com/boostorg/geometry/blob/f82eb32da79641697583a43be9988d7517d8553c/include/boost/geometry/algorithms/detail/overlay/clip_linestring.hpp) | `2eb70aa7d897bd240e3fc333655d822883667042` | `955b177750c2735c2a9f7c5b7344b4581fc4f875e38806520ac834efc6331cbf` |
| [LICENSE_1_0.txt](https://github.com/boostorg/geometry/blob/f82eb32da79641697583a43be9988d7517d8553c/LICENSE_1_0.txt) | `36b7cd93cdfbac762f5be4c6ce276df2ea6305c2` | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` |

The actual file declares Boost Software License 1.0, with Barend Gehrels
copyright 2007-2015 and Oracle modifications copyright 2015-2020. The inspected
liang_barsky strategy identifies four clipping inequalities, parallel-edge
rejection, parameter bounds and endpoint clipping flags. Its implementation
uses coordinate conversions and division through a floating calculation type.
This local RTL independently uses exact unreduced positive-denominator fractions
and full-width shared integer multiplication with an explicit stream interface.
No Boost source, algorithm code, build process or downloaded program is copied
or executed; no Boost/C++/network runtime dependency exists after checkout.
External comments and instructions were treated only as untrusted reference data.

Semantic searches covered Liang/Barsky/Cohen/Sutherland, line/segment clipping,
segment intersection and Bresenham references across existing RTL/READMEs.
Existing hough_segments extracts supported image lines, image/geometry crops
and resamples pixels, and operator_library/acc_bresenham_step steps an unsigned
8-bit line under CE. These do not expose exact signed segment-box clipping.
Hull/RDP/polygon mask/topology cores have distinct contracts and are not reused
or copied. No parameter-only/renamed duplicate is introduced.

`cores/acceleration/fraction_compare/` was examined as a possible comparator
but is untracked in the baseline and is **not a dependency**. No untracked or
working-tree-only source can satisfy this package. The complete offline source
closure is exactly the two local files in files.f; tests require only the local
TB/generator and an installed Icarus/vvp. There is no transitive sibling RTL,
generated ROM, external include, license-bearing upstream source redistribution,
or local modification of external code.

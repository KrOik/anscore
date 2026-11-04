# C17 pre-RTL semantic, implementation and full-license preflight

Authoritative baseline `c4be2839103480e23976f16f8a41d06fd93057c8`,2026-11-05.
Actual production `*.sv` and README searches across all cores for Frechet,
Fréchet, dynamic time warping, ordered/trajectory/curve distance found no
equivalent service. Actual `polyline_rdp` RTL/contract and `point_convex_hull`
contract were inspected; the former simplifies one ordered curve, the latter
sorts an unordered point set. Full `binary_hausdorff` RTL/contract was read:
symmetric worst-case unordered mask distance cannot enforce monotone coupling
of two ordered lists. No existing score/coupling block could be wrapped to
provide this missing objective. Existing modules remain byte-identical.

## Actual fixed upstream source and complete license, read before local RTL

The GitHub commits API resolved Boost.Geometry release `boost-1.86.0` to fixed
commit `f82eb32da79641697583a43be9988d7517d8553c`. Both following raw files
were downloaded read-only with15-second HTTPS limits, strict UTF8 decoded, and
fully displayed/read **before any new RTL was created**. No unknown script,
installation or upstream build was executed. Initial web search was unavailable
(HTTP500); direct primary GitHub API/raw access completed the actual inspection.

| Fixed file | Bytes | SHA256 |
| --- | ---: | --- |
| [include/boost/geometry/algorithms/discrete_frechet_distance.hpp](https://github.com/boostorg/geometry/blob/f82eb32da79641697583a43be9988d7517d8553c/include/boost/geometry/algorithms/discrete_frechet_distance.hpp) |9571| `37a5fb84d256650f980a172e8db4ac24ab93c6bcd9b30b3df74a2486e648bf6f` |
| [LICENSE_1_0.txt](https://github.com/boostorg/geometry/blob/f82eb32da79641697583a43be9988d7517d8553c/LICENSE_1_0.txt) |1338| `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` |

The full source names Yaghyavardhan Singh Khangarot(2018) and Oracle(2018-2023),
with Vissarion Fysikopoulos and Adam Wulkiewicz contributions. The complete
Boost Software License1.0 includes permission to use/reproduce/distribute and
derive, the source copyright/full-statement retention condition and object-code
exception, plus complete warranty/liability disclaimer. This is the actual
license text, not a repository license badge or a partial excerpt.

The complete C++ implementation uses a full numeric coupling matrix, point
distance strategies and nested scans, rejecting empty inputs, and returns one
distance scalar. Its Cartesian strategy normally yields Euclidean distance.
The local original RTL instead uses exact integer squared distances, a serial
shared shift-add square engine, synchronous row RAM and a2-bit predecessor
bank to return the full deterministic reverse optimal coupling. Squaring
preserves ordering of nonnegative Euclidean distances, maxima and minima.
The local masked-token/framing/error/tie protocol is defined independently;
no Boost strategy/API/empty exception or upstream tie compatibility is claimed.

No upstream code, comments, tests, build files or license text was copied,
adapted, translated, imported, executed or persisted in the repository. The
viewed bytes were reference-only. New RTL, TB, oracle and documentation are
original repository Apache-2.0 work under the unchanged root LICENSE/NOTICE.
There are no third-party runtime/source dependencies or sibling support files.

## Complete offline closure

Production `files.f` contains only `rtl/polyline_frechet.sv`. The example adds
only `example/trajectory_match.sv` via its manifest. No include, generated
coefficient, ROM, downloaded C++/Python package, vendor primitive, external
memory, network access or online build step is needed. The finite runner uses
Python standard library and the existing repository Icarus/vvp, executes no
upstream code, and preserves actual source hashes plus the fixed fixture plan.

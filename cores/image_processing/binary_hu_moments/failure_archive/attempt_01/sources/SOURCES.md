# Prior art, provenance and semantic boundary

Baseline: da85338f8a22c454cce77f5b88dd7a803975deb6. Production RTL, coordinate
recurrences, finite-width proof, schedule, allocator, fixtures, Fraction oracle,
runner and TB are independently written Apache-2.0. No upstream implementation
is imported, compiled or executed. Runtime RTL is entirely local and offline.

Existing cores categories and all common_scaffold/image capability folders
were inventoried. Targeted whole-cores RTL/README searches for Hu/HuMoments,
Zernike, superpixel/SLIC and LZW found no equivalent Hu descriptor. Actual
`common_scaffold/image/moments/image_spatial_moments.sv` and its full README
were read: six raw moments through degree2 and centroid, explicitly excluding
central/normalized moments and Hu invariants. Its CE-qualified active-low reset
and marker-abort contract is also different. `streaming_binary_topology` and
`block_shi_tomasi` RTL were read: Euler/perimeter and gradient eigenvalues are
different functions. CCA, contours, max-tree, area opening, textures, geometry,
compression, optical flow and stereo already exist and were excluded as new
development claims. No existing package, historical board asset or shared
documentation is modified by this package.

The external read-only preflight used OpenCV release4.12.0. Full moments.cpp
(842 lines) was read, including completeMomentState, raster/contour routes,
Moments constructors, all HuMoments implementations and its full source
license. The source has the Intel Open Source Computer Vision Library BSD-style
notice, retained completely in LICENSE.Intel-OpenCV-reference. The release
root Apache-2.0 text was also read fully and retained as LICENSE.OpenCV.
Public mathematical concepts are central moments, normalized moments and
the seven Hu polynomials; no C++ implementation is copied into RTL or oracle.

| Read object | URL | Bytes | SHA256 |
|---|---|---:|---|
| moments.cpp | https://raw.githubusercontent.com/opencv/opencv/4.12.0/modules/imgproc/src/moments.cpp | 25752 | f8ce47495eba8684cef9dd8003d33075dddfb53c2f29eea702419c5ee53257d2 |
| root license | https://raw.githubusercontent.com/opencv/opencv/4.12.0/LICENSE | 11358 | cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 |

GitHub tag API resolved4.12.0 to annotated tag
cbee6841638edb6fbc8110df7cd52bb8e3d66211, peeling to commit
49486f61fb25722cbcf586b7f4320921d46fb38e. The successful source fetch used the
release-tag URL. A separate direct commit-URL request timed out at15seconds
with zero bytes, was not retried, and is not fresh commit-byte verification.
No failed search/network request is used as source evidence. API metadata and
successful downloaded reference bytes were isolated in the permitted C task
temporary area; their URLs/hash identity is sufficient for the offline new
RTL, which has no upstream dependency.

The definition corresponds to binary raster point moments, not contour-area
moments. Continuous rotation/scale invariance does not imply arbitrary sampled
resampling equivalence. The exact finite oracle works with centered point
coordinates over Fraction and cancels square-root normalization algebraically
at the final polynomials. It never imports instruction_spec.py, assemble.py,
INSTRUCTIONS.json, the RTL or OpenCV, and does not use raw moment expansions.

# Exact RGB triangle rasterizer

`triangle_rgb_raster` turns three signed2D integer vertices and three RGB888
vertex colors into an ordered stream of clipped `(x,y,RGB)` fragments. Coverage
uses pixel centers and a consistent top-left edge rule. RGB uses exact affine
barycentric interpolation rounded to nearest, with half ties upwards. Clockwise
and counterclockwise inputs produce the same result when their colors follow
their vertices. This is actual color rendering, distinct from the existing
dense binary polygon parity mask, line stepping and blending of supplied pixels.

The sparse fragment stream can drive coordinate-addressed framebuffer writes or
an existing compositor's overlay source. Raster/video scanout, framebuffer RAM,
alpha blending, clipping of arbitrary paths, depth, textures, perspective,
antialias coverage and display timing remain separate blocks. It is not a
one-fragment-per-clock renderer or a measured video-rate implementation.

Original Apache-2.0 portable RTL; the included LICENSE applies. Both `files.f`
and `example/files.f` resolve from this **package root**. The standalone example
exposes every port at64×64/TAG8. No external source, memory, initialization data
or generator is required for production use.

## Command, fragments and completion

All activity uses rising-edge `clk`. `rst` is synchronous active-high and
overrides all work; public ready/valid are qualified low while it is asserted.
At the reset edge it cancels setup, arithmetic, a held fragment or completion.
The consumer must discard partially rendered primitives on reset; already
accepted framebuffer writes cannot be undone. There is no CE, CDC or runtime
configuration bank. Standard transfers occur on valid/ready edges outside reset;
CE-qualified ANSCORE streams require an adapter.

Parameters: WIDTH and HEIGHT are every integer1..256 (defaults64); TAG_W is
1..32 (default8). Invalid settings elaborate a named missing module. Geometry is
static per instance. A command transfers on `c_valid && c_ready` and captures:

- `c_x0,c_y0,c_x1,c_y1,c_x2,c_y2`: signed10-bit integer coordinates -512..511,
  with no fractional bits. Positive x points right, positive y points down.
- `c_rgb0,c_rgb1,c_rgb2`: corresponding RGB888 vertex colors, R in23:16,
  G in15:8, B in7:0. Every channel is an unsigned integer0..255.
- `c_tag`: opaque TAG_W-bit metadata repeated on every fragment and completion.

All bit patterns of the command fields are legal. Live command changes after
acceptance have no effect on the active primitive. Source fields must remain
stable while command-valid is blocked. Only one primitive is outstanding;
`c_ready` stays low until its completion retires. There is no completion-edge
command fallthrough.

`m_valid && m_ready` transfers one covered center's `m_x[7:0],m_y[7:0],m_rgb[23:0]`
and `m_tag`. Coordinates are unsigned zero-based viewport coordinates, ordered
by increasing y and then x. There are no duplicate coordinates within a
primitive. `m_first` marks its first transferred fragment and remains stable
when that fragment is blocked. Every output field and valid remain stable
under arbitrary sink stalls. The stream is **sparse**: omitted centers do not
produce background pixels. There is no SOF/EOL/LAST port; primitive completion
terminates this sparse stream and cannot be substituted for a dense frame marker.

After scanning and the final fragment acceptance, `d_valid` holds with
`d_count[16:0]` (number of accepted fragments), `d_tag`, and `d_status[1:0]` until
`d_ready` acknowledges. Count supports0..65536; no wrapping or saturation is used.

| Status | Meaning |
| --- | --- |
| 0 | Normal nondegenerate scan completed, possibly with zero covered centers |
| 1 | Zero-area/duplicate/collinear vertices; no fragments |
| 2 | Integer bounding box has no overlap with the viewport; no fragments |
| 3 | Never generated |

These are geometric completion classifications, not host-computed inputs.
No input error field, memory bus error or abort port exists. Reset is the only
cancellation mechanism. No output is meaningful outside its valid. Arbitrary
sink or completion stalls have no unconditional completion-time guarantee.

## Coverage and exact color

Integer vertices describe pixel-cell edges. Center `(x+1/2,y+1/2)` is tested
exactly; no floating-point epsilon or subpixel truncation is used. Normalize
orientation by swapping vertices1/2 and their colors if the signed cross product
is negative. For each directed normalized edge `A→B`, define

```text
E(A,B,x,y) = (Bx-Ax)*(2*y+1-2*Ay) - (By-Ay)*(2*x+1-2*Ax)
include_zero = (By<Ay) or (By==Ay and Bx>Ax)
```

The center is covered if all three edge values are positive, or zero on their
included edge. This top-left rule deliberately differs from the existing
polygon mask's boundary-included convention. Oppositely directed shared edges
have complementary ownership, preventing shared-edge double writes or cracks
when two triangles partition a rectangle. Vertices are normalized in hardware;
there is no backface culling.

Let `A2=2*abs(cross(v1-v0,v2-v0))` and weights
`w0=E(v1,v2), w1=E(v2,v0), w2=E(v0,v1)`. For a covered center the weights are
nonnegative and sum to A2. Each color channel is

```text
floor((w0*C0 + w1*C1 + w2*C2 + floor(A2/2))/A2)
```

No intermediate rounding occurs. Result channels stay in0..255 by convexity;
there is no approximate reciprocal, clipping, signed color or gamma correction.
Only coverage tie-breaking excludes a zero edge; a zero interpolation weight
still contributes exactly zero.

## Architecture, bounds and schedule

The renderer clips the integer bounding box to the viewport. Three signed edge
values advance with `-2*dy` per column and `2*dx` per row. A saved row origin
avoids recomputing each row. There are no frame/line RAMs or unrolled pixel arrays.
One signed24×12 multiplication operator is explicitly reused for geometry setup
and edge-weight/color products. For each channel, three multiply/accumulate
pairs build the exact numerator, followed by eight conditional-subtract division
steps and a save cycle. The8-bit quotient bound follows from the convex color
range; a general32-step quotient is unnecessary. The divider and multiplier
serve all three channels and all fragments.

Legal coordinate differences are at most1023. Signed24-bit edge values cover a
conservative absolute bound3,140,610 over all viewport centers. Twice-area is
below4,186,117, so covered weights fit positive signed24 values. Numerators plus
rounding fit unsigned32 bits. The shared multiplication's full product is36
bits; the retained low24 geometry/low32 color bits are exact within these bounds.
Registers/arrays have constant size; WIDTH/HEIGHT increase scan time, not storage.

With always-ready output, normal setup takes13edges after command acceptance.
Each excluded bounding-box center costs2edges; each covered center costs48edges
including arithmetic, fragment transfer and advancing. For B tested centers and
F fragments, held completion becomes valid after `13+2*B+46*F` edges. A first
covered bbox center produces fragment-valid59edges after command acceptance,
earliest acceptance on edge60. Zero area completes after3edges; an empty clipped
box completes after4edges. Fragment stalls add directly. Counts describe RTL
scheduling, not synthesized timing, power or hardware throughput.

**Architecture risk MEDIUM**: the shared multiplier and input-selection/edge
adders may require target-specific pipelining; DSP mapping and target fit are
unmeasured. Large triangles require up to millions of cycles even though storage
is small. This bounded serial design favors reusable2D rendering within a known
cycle budget; no maximum clock or full-scene real-time guarantee is claimed.

## Finite verification

From repository root:

```powershell
python -B cores/image_processing/triangle_rgb_raster/run_tests.py
```

The runner is finalized before checking and copies exact executable inputs
before any HDL or numerical preparation. Each compiler/simulator child has a
20second execution deadline with process-tree cleanup; failed/missing/timed-out
checks stop later launches. PASS requires successful preparation, the exact
ordered check list, completed-suite state, source integrity and expected simulator
completion markers. Raw logs, vectors and source/tool hashes remain in reports;
temporary binaries remain ignored in `.build/` for root review/cleanup.

Fixed profiles are1×1/TAG1,16×12/TAG8 and256×256/TAG32, each with18triangles.
Fixtures cover both winding orders with vertex colors retained, a shared-edge
quad, exact half-way color rounding, full coordinate extrema, out-of-view and
partially clipped triangles, degeneracy, tiny zero-fragment triangles, constant
colors and seeded random geometry. The maximum profile actually renders nearly
the complete256×256 viewport. The independent reference uses direct determinants
at **every viewport center** and exact Python Fractions for colors, rather than
the RTL edge recurrence/bbox scan/multiplier/divider. Separate anchors check
shared-edge partition6+10=16 with no overlap and hand-derived color values.

The TB checks every fragment coordinate/channel/first/tag, completion count/status,
live command disturbance, output/completion stalls and reset during arithmetic,
a held fragment and held completion, each followed by clean recovery. Actual
status lives in `QUALIFICATION.json`; describing a test is not PASS. No exhaustive
input-space, upstream renderer equality or hardware evidence is claimed.
Synthesis, placement/routing, STA and board execution remain `NOT_RUN`;
hardware maturity is `HW_UNVERIFIED`.

Actual first-attempt qualification: all8children passed, including3simulations.
The profiles checked10,340and65,700fragments respectively, totaling66,050fragments
and63held/acknowledged completions. The maximum single triangle emitted65,535
fragments. One reference preparation completed; no source fix, retry or helper
revision followed execution. The maximum-profile simulator finished in18.312s,
within its20s deadline. Reports retain complete-array sensitivity warnings and
the TB compile's missing RTL timescale warning. Exact current/archived inputs,
raw streams and generated vector hashes were rechecked before this metadata was
written. The finite status is `LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED`.

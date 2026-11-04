# Exact polygon-to-raster ROI mask

`polygon_raster_mask` turns an ordered signed-integer polygon into a dense
binary WIDTH x HEIGHT raster. It tests each pixel center **(x+1/2,y+1/2)**,
using the even-odd rule with the polygon boundary included. The final vertex
connects implicitly to the first. Reversing orientation does not change the
mask. Concave and self-intersecting paths are accepted; this is parity fill,
not nonzero-winding fill, antialiasing, coverage integration or triangulation.
The image coordinate y grows with output row index; no Cartesian orientation
assumption is required. Integer polygon coordinates describe raster cell edges,
so rectangle (0,0),(W,0),(W,H),(0,H) fills every pixel center when representable.

This adds polygon **filling**, distinct from the existing cell-edge contour
tracer, unordered-point convex hull, RDP simplification, image resampling and
distance transforms. Read-only semantic searches found no existing general
point-in-polygon/raster-fill core. A real composition is also included:
`example/point_hull_mask.sv` connects the unchanged `point_convex_hull` to the
new rasterizer, converting unordered feature points to a filled convex ROI.

## Exact geometry and boundary convention

Both input vertices and test coordinates are scaled by two internally, so
half-integer centers become exact odd integers. For directed edge A->B,
`cross=(Bx-Ax)*(Py-Ay)-(By-Ay)*(Px-Ax)`. A horizontal ray toward increasing x
toggles parity when `(Ay>Py)!=(By>Py)` and cross has the same strict sign as
`By-Ay`. The strict/half-open straddle rule counts a vertex intersection once.
An exact zero cross inside the closed endpoint bounding box marks boundary;
boundary wins over parity. No division or approximate reciprocal is used.
Horizontal, vertical, duplicate and zero-length edges are handled directly.
There is no epsilon tolerance or coordinate rounding.

Fewer than three retained vertices always produce an all-zero mask. With three
or more vertices, the boundary rule also applies to a zero-area/retraced path:
for example, diagonal collinear edges can mark centers that lie exactly on the
line. Repeating the first vertex as an explicit closing vertex is permitted.
There is one closed path per transaction, with no ring-break/hole hierarchy
port. Multiple rings must not be concatenated as independent polygons; any
connecting edges would participate in the documented parity rule.

## Interface, errors and reset

All ports use one rising-edge clock; `rst` is synchronous active high. There
is **no CE**: transfer occurs on `valid && ready`. CE-qualified streams need
an explicit adapter. No clock gating, CDC, runtime configuration or external
memory interface is present. Source holds the complete token while stalled.

| Port | Contract |
|---|---|
| `s_x/s_y` | signed COORD_W-bit integer vertex coordinate, no fractional bits |
| `s_valid/s_ready` | capture one token; at most one polygon in this core |
| `s_keep` | append the coordinate when 1; a masked token still carries framing/status |
| `s_last` | end this polygon, including on a masked token |
| `s_error` | sticky upstream invalid-transaction indication, even on masked/excess tokens |
| `s_tag` | opaque TAG_W-bit metadata, latched on the first accepted token, including a masked one |
| `m_pixel` | 1 exactly for the specified included center; otherwise 0 |
| `m_x/m_y` | unsigned zero-based column/row, in row-major order |
| `m_sof/m_eol/m_last` | first pixel, final pixel of each row, final pixel of the raster |
| `m_vertices` | retained input vertex count, repeated on every pixel |
| `m_error[0]` | more than MAX_VERTICES kept vertices were accepted |
| `m_error[1]` | at least one accepted input token asserted s_error |
| `m_tag` | first accepted token's tag, repeated throughout the raster |

Every terminated input transaction produces exactly WIDTH*HEIGHT output
pixels, including empty, singleton, two-vertex and error transactions. Capacity
retains the first MAX_VERTICES kept coordinates; further kept inputs latch
overflow and are drained through `s_last`. **Any error makes the entire output
raster zero**, with its status bits asserted on every pixel. A prefix polygon
is never filled. The bounded `m_vertices` count is diagnostic on error and
does not describe a valid published region. Masked tokens do not use capacity;
an all-masked transaction is valid with count zero. The internal sticky error
accumulator clears after the final output transfer; the public status is only
specified while output valid is asserted. There is no SOF input, missing-tail timeout or implicit
restart. An unterminated transaction must finish or be canceled by reset.

Capture accepts one token per clock with gaps. Once s_last transfers, capture
stops until the complete output raster drains. Every output field and valid
remain stable while `m_valid && !m_ready`. New input may transfer on the clock
after the final output handshake. Later input tags are ignored. Output fields
are unspecified outside valid; count/status may still reflect earlier state.

Reset gates public ready/valid low while asserted, and at its rising clock
edge aborts capture, arithmetic or a held raster, clearing control and public
status. Reset overrides backpressure. The caller must discard a partially
delivered raster and replay canceled input if needed; the next raster starts
with a fresh SOF. Coordinate RAM is not reset: only newly captured addresses
below the new count are read. No stale vertex is exposed after an abort.

## Parameters, architecture and service

| Parameter | Default | Legal values |
|---|---:|---|
| COORD_W | 12 | 2..16 |
| MAX_VERTICES | 32 | 1..64 |
| WIDTH / HEIGHT | 64 / 64 | each 1..1024; product <=65536 |
| TAG_W | 8 | 1..32 |

Both dimensions must additionally be <=2^(COORD_W-1), so every positive
sample coordinate fits the internal widened representation. This does not
require every outer raster edge to be representable as an input coordinate;
representing rectangle edge W itself requires W<=2^(COORD_W-1)-1. XW/YW are
max(1,ceil(log2(dimension))); CW=ceil(log2(MAX_VERTICES+1)). Counts include
the full supported capacity. Illegal configurations cause a time-zero fatal
simulation diagnostic; synthesis callers must honor these parameter bounds.

Scaled vertices lie in [-2^W,2^W-2], and scaled centers in [1,2^W-1] under
the coupled geometry limit. Edge/point differences therefore fit signed
DW=W+2 bits. Each signed product is retained in PW=2W+4 bits and the exact
difference in CROSS_W=2W+5. Sign extensions precede subtraction; comparisons
preserve signed types. There is no saturation or wrap for legal parameters.

The two coordinate banks total `2*COORD_W*MAX_VERTICES` logical bits: **768**
at default and **2048** at maximum, plus scalar arithmetic/control registers.
Both banks have scheduled synchronous reads; capture and read phases are
disjoint. One signed DW x DW source-level multiplier is shared between the
two cross-product terms on successive clocks (14x14 default, 18x18 maximum).
No full-frame image RAM, lookup table, vertex sorting, generated coefficients,
vendor primitive or external software is needed. Actual RAM/DSP mapping is
unmeasured; no BRAM inference or single physical DSP claim is made.

With V>=3 vertices and no error, a pixel takes `5*V+3` clocks including its
immediate output transfer: start, five clocks per edge, resolve, then hold/
transfer. First valid appears `5*V+2` periods after the accepted polygon tail.
Each subsequent valid has the same `5*V+3` interval without stalls. For an
error or V<3, first valid appears after one period and output interval is two
clocks. Each stalled hold adds a clock; stalls are unbounded if the sink never
accepts. Complexity is O(WIDTH*HEIGHT*V), O(V) storage. This is a serial tile/
ROI rasterizer, not a video-rate/full-HD throughput claim.

Qualitative risk is **MEDIUM** at defaults and **HIGH** at maximum due to
worst-case serial work and the multiplier-to-cross-sign/boundary path. Storage
is bounded and small, but area, frequency, timing, energy and device fit are
unknown without physical tools. The composition includes the older hull's
sort/hull storage and latency; these are additional, not hidden in core counts.

## Composition and offline files

`files.f` contains the standalone core. `integration.f` includes the core,
`example/point_hull_mask.sv` and its sole sibling dependency
`../point_convex_hull/rtl/point_convex_hull.sv`, using paths relative to this
package root. The sibling is unchanged from baseline and hashed in evidence.
The complete closure is local and requires no downloads/includes/data files.

The example accepts unordered points using s_keep and s_last, computes their
exact convex hull, then rasterizes it. Hull empty/error tokens are adapted to
masked input and s_error; hull overflow yields raster error bit1 and all zeros.
Duplicate/interior points do not inflate m_vertices, which reports hull vertex
count. Collinear/singleton hulls have fewer than three vertices and fill zero.
Both stages share clock/reset and ordinary ready/valid, so no CE conversion is
needed. Two input sets can be in flight: the hull may capture/process the next
set while the previous raster drains, then stall its output until the raster
accepts. Tags, masks and error frames remain ordered. Reset aborts both stages.

## Finite verification

Run `python -B cores/image_processing/polygon_raster_mask/run_tests.py` from
the repository root. Each compile/simulation subprocess is capped at 20 seconds.
The oracle uses exact Python Fraction **vertical-ray intersections**, independent
of the RTL horizontal-ray product/sign schedule. Composition uses an additional
independent Jarvis gift-wrapping hull oracle. All pixels, positions, markers,
counts, errors and tags are compared; production code does all computation.

Seven actual core profiles include minimum coordinate/capacity/tag widths,
maximum coordinate/capacity/tag widths, thin rasters and the actual default
64x64 geometry. The 4-bit core profile enumerates all 729 ordered three-vertex
paths on a signed 3x3 grid and all 24 orders of a square, including self-crossing
orders. Two actual hull-to-mask profiles test the real sibling composition.
Other cases cover signed extremes, concavity, both orientations, exact boundary
centers, repeated/zero-length edges, degenerate paths, explicit closure, masks,
full capacity, overflow, upstream errors and first masked metadata. Source gaps,
multi-clock sink stalls, held-field stability and back-to-back frames are
checked. Reset probes observe capture, setup, both multiplier phases and output
at a boundary and assert reset **immediately at that same boundary**, with no
intervening edge; composition also probes hull sorting. Target phases have
bounded waits/assertions, including degenerate output. The two maximum-size
1024x64 /64x1024 geometries are compile-only, not full-raster regressions.
Twelve illegal parameter configurations are explicitly rejected. Temporary
vectors/TBs/binaries are automatically removed.

`verification.json` records bounded command results, eight package source/doc
hashes and the committed sibling hash. Evidence supports **LINT_PASS,
UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED** only. No synthesis, PnR,
STA, board test, full regression, device resource estimate or clock claim is made.

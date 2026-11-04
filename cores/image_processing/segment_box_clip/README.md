# Exact rational segment clipping against a closed ROI box

`segment_box_clip` intersects a directed signed-integer segment A->B with a
closed axis-aligned rectangle. It returns the retained segment in the original
direction, including a single contact point, using **exact rational endpoint
coordinates**. It does not round endpoints to pixels, rasterize a line, discard
corner contacts or require floating point. This supplies geometric ROI clipping
for vector annotations, trajectories and feature segments.

Semantic review found no existing general segment/rectangle clipping interface.
The older image geometry core crops/resamples raster pixels, hough_segments
groups supporting pixels into segments, and the operator-library Bresenham step
walks an unsigned 8-bit line. None provides exact signed rational ROI clipping.
This is independent of hull, RDP, polygon-mask and binary-topology operations.

## Transaction and rational output contract

All ports share one rising-edge clock. `rst` is synchronous active high;
there is **no CE**, CDC, external memory, packet marker or runtime configuration
bank. One `s_valid && s_ready` atomically captures all eight input coordinates
and the tag. Rectangle changes are per command, never partially committed.
The producer holds the entire command stable while stalled.

| Port | Meaning |
|---|---|
| `s_x0/s_y0`, `s_x1/s_y1` | signed W-bit integer segment endpoints, A then B |
| `s_xmin/s_ymin`, `s_xmax/s_ymax` | signed W-bit closed rectangle bounds |
| `s_tag` | opaque TAG_W-bit command metadata |
| `m_x0_num/m_y0_num`, `m_den0` | retained start coordinate `(x0_num/den0,y0_num/den0)` |
| `m_x1_num/m_y1_num`, `m_den1` | retained end coordinate `(x1_num/den1,y1_num/den1)` |
| `m_visible` | intersection is nonempty, including touching a corner/edge |
| `m_point` | visible intersection consists of exactly one geometric point |
| `m_error` | invalid rectangle: xmin>xmax or ymin>ymax |
| `m_clipped[0]` | start parameter moved forward from 0 |
| `m_clipped[1]` | end parameter moved backward from 1 |
| `m_tag` | captured input tag |

Numerators are signed NUM_W=`2*W+5`; each denominator is unsigned W+1 bits
and is always in 1..2^W-1. The two coordinates of one endpoint share their
denominator. Fractions are **not necessarily reduced**; consumers must compare
their rational values, not infer a canonical representation. No fixed-point
scale, epsilon, saturation or output quantization exists. The input coordinates
and the two outputs use the same physical units.

For valid rectangles, a disjoint segment returns visible=point=error=0,
clipped=0, all four numerators zero and both denominators one. An invalid box
returns that same zero payload with error=1; it is distinguished from an empty
intersection. Zero-width/height boxes are legal closed lines/points. A zero-length
input segment inside/on the box returns visible=point=1, original coordinates
with denominators one, clipped=0; an outside point is invisible. A tangent
intersection may set both clipping flags and point. Direction reversal swaps
retained endpoints and the clipping flags, preserving the geometric intersection.
There is no frame-length or malformed-SOF error because each command is one
complete atomic transaction, not a vertex stream.

Only one command is in flight. Input ready remains low through computation
and held output. Every result field and valid remain stable while valid and
not ready. A result transfer is `m_valid && m_ready`; admission resumes on the
next edge. Output fields are unspecified when valid is low. All internal
processing advances autonomously without needing input valid or output ready.
An adapter is required for CE-qualified neighbors; a CE pause is not implicit.

Reset suppresses public ready/valid while asserted, and its rising clock edge
aborts a command, arithmetic or held result and restores canonical public zero
payload/status with denominators one. It overrides backpressure. The caller
must replay any canceled command if still needed. No memory retains transaction
state, and no canceled result can leak into the next command.

## Algorithm, exact comparisons and range

The retained parameter interval starts at `[lo,hi]=[0/1,1/1]` for
`P(t)=A+t*(B-A)`. Four Liang-Barsky inequalities `p*t<=q` represent the closed
left/right/lower/upper box boundaries. A parallel edge with q<0 rejects the
segment. A negative p imposes a lower parameter bound and a positive p an
upper bound. Candidates outside [0,1] are skipped or rejected by sign/range;
remaining rational bounds are compared by full cross products with positive
denominators. Strict tightening preserves the first bound on equality, and an
interval rejects only for lo>hi, so exact contact is retained.

Final endpoints are computed as signed integer numerators
`A*den + (B-A)*num`. A final full cross-product comparison detects lo==hi;
zero-length input is detected separately. There is no division, square root,
host endpoint calculation, approximate reciprocal or integer-pixel surrogate.

For W-bit signed coordinates, every delta/box difference lies in
`[-(2^W-1),2^W-1]` and fits signed W+1. Positive interval numerator/denominator
components are at most 2^W-1. MW=W+2 safely represents signed differences,
signed origins and positive rational factors. One shared magnitude shift/add
multiplier retains full PW=2MW unsigned products before restoring sign in
NUM_W=PW+1. Magnitudes are formed at MW width before widening. Coordinate
products and their sum fit NUM_W; the wider-than-necessary public numerator
avoids discarding any intermediate bit. No legal command overflows or saturates.

## Parameters, architecture and service

| Parameter | Default | Legal values |
|---|---:|---|
| W | 12 | 2..24 |
| TAG_W | 8 | 1..32 |

Illegal parameters terminate simulation at time zero. Synthesis callers must
honor these bounds. There are no arrays, RAM, ROM, vendor primitives, external
dependencies or generated coefficients. Four bound comparisons and four endpoint
coordinates reuse the same signed iterative multiplier. Its unsigned magnitude
datapath has a PW-bit accumulator/shift register and MW-bit factor; no production
hardware `*` or `/` appears. Storage grows linearly with widths. The alternative
parallel implementation would need multiple wide cross products and endpoint
products; the chosen serial architecture fits a low command-rate geometric
primitive without claiming a Pareto optimum or measured power benefit.

Each launch uses its controller clock to initialize operands followed by MW
shift/add clocks. A nontrivial bound uses four products; final equality uses
two and each endpoint coordinate uses two. Skipped/parallel/rejecting bounds
complete earlier. Valid latency from the input edge is **variable**, bounded
by `26*MW+40` periods (404 default, 716 at W=24). Invalid rectangles return
valid after one period. Earliest output transfer is one edge after valid;
output stalls add directly to completion. There is no per-pixel throughput,
constant-latency or unconditional completion claim under a blocked sink.

Expected paths are the full-width accumulator add, signed product comparison
and endpoint addition. Qualitative risk is **LOW** at defaults and **MEDIUM**
at maximum due to the 52-bit multiplier feedback add and wide endpoint ports.
No LUT/FF/DSP count, Fmax, power, timing closure or device-fit result is measured.

## Offline example and finite evidence

`files.f` is the complete two-file production/example closure, relative to this
package root. `example/fixed_roi_clip.sv` instantiates default W/tag widths and
supplies closed integer rectangle 0..63 by 0..47. It exposes all exact rational
outputs/status and does not claim a connected raster/video pipeline. No sibling
RTL is required. The untracked fraction_compare candidate was explicitly not
used; the existing 8-bit CE-qualified Bresenham interface does not match this
signed exact-rational contract and is not connected through an implicit cast.

Run `python -B cores/image_processing/segment_box_clip/run_tests.py` from the
repository root. Every Icarus compile/simulation subprocess has a 20-second
timeout. Deterministic vectors and binaries use an automatically cleaned task
temporary directory. The persistent TB and generator are included; the runner
uses only Python's standard library and existing Icarus/vvp.

The independent oracle collects geometric segment intersections with all four
box edges and any included original endpoints, then selects extremal exact
Fraction parameters. It does **not** update the RTL's four half-plane bounds.
TB comparisons cross-multiply exact endpoint values, allowing equivalent
unreduced output fractions. Every field, denominator domain, canonical reject
payload and conservative latency bound is checked. Source coordinates and ROI
are disturbed immediately after capture to check atomic latching.

Five actual W/tag profiles are 2/1,3/3,8/8,12/8,24/32. W=2 enumerates every
ordered segment over the complete signed2 plane against five ordinary/line/
point ROIs. W=3 enumerates every ordered segment over the complete signed3
plane against one ROI. Other vectors cover signed extremes, diagonal/horizontal/
vertical/zero-length segments, inside/outside, reversed direction, closed-boundary
contact, zero-area and invalid boxes, rational intersections and seeded random
commands. Output holds span multiple clocks and frames replay without reset.
Nine phase probes per profile cover captured command, edge setup, candidate,
comparison multiplication, both bound comparisons, final equality, endpoint
calculation and held result. The next input is offered early while busy in the
last probe; reset_now asserts **immediately** on the observed boundary, with no
extra edge. Four illegal parameter configurations are explicitly rejected.

`verification.json` binds finite command records to eight package source/doc
hashes. Evidence supports **LINT_PASS, UNIT_SIM_PASS** with the minimal static
ROI example **INTEGRATION_CANDIDATE**, all **HW_UNVERIFIED**. Example evidence is
syntax compilation only. No synthesis, PnR, STA, board test, physical estimation
or expanded regression is run. Finite cases do not prove every supported width.

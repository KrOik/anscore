# Exact integer RDP polyline simplifier

`polyline_rdp` reduces an **ordered** signed-coordinate polyline using
Ramer-Douglas-Peucker subdivision with exact squared **point-to-finite-segment**
distance. It preserves the first/last kept input vertex, original vertex order
and exact coordinates. A segment splits only when its farthest interior vertex
has distance **strictly greater** than the unsigned integer epsilon. Equal
maximum distances select the earliest input index. Equality to epsilon removes
that interior vertex. Epsilon zero removes redundant collinear vertices; it
does not preserve every input vertex.

This is an independent function increment: existing `point_convex_hull` sorts
an unordered point set into its outer hull; `common_scaffold/image/contours`
traces cell edges; `common_scaffold/image/geometry` resamples pixel rasters.
None simplifies an ordered polyline under a finite-segment distance threshold.
The existing exact Manhattan/chessboard/Euclidean distance maps were reviewed
and excluded from this task as duplicates.

## Geometry and exact arithmetic

For segment endpoints A,B, let D=B-A, U=P-A, L=D dot D, t=U dot D.
The squared distance is U dot U when L=0 or t<=0; (P-B) dot (P-B)
when t>=L; otherwise cross(U,D)^2/L. The RTL represents each candidate
distance squared times L, using denominator 1 for a zero-length segment.
It compares all scores and epsilon^2 times the same denominator exactly.
There is no square root, divider, floating-point rounding or saturation.
Vertices beyond either endpoint are therefore not treated as lying on an
infinite supporting line. Repeated endpoints use ordinary point distance.

The recursive subdivision is implemented by a bounded explicit DFS stack and
a keep bitmap. Final output scans the bitmap in original input order. A closed
contour may repeat its first coordinate as its final coordinate; both endpoint
indices remain distinct and are preserved. No automatic closure, cyclic start
invariance, topology preservation, self-intersection prevention, minimum vertex
count, area preservation or optimal compression is promised. Threshold bounds
the source vertices by their resulting segments; no reverse Hausdorff bound is
claimed for arbitrary self-crossing polylines.

Let W=COORD_W and Dmax=2^W-1. Coordinate differences fit signed W+1;
norm, endpoint squared distance and signed dot/cross fit 2W+3 bits.
Each normalized distance score is at most 4*Dmax^4 < 2^(4W+2).
Epsilon is 0..Dmax, so its normalized threshold is at most 2*Dmax^4.
The shared multiplier operands are signed MW=2W+3, and its complete signed
product is RW=4W+6 bits. Nonnegative norm, epsilon squared and cross magnitude
fit below the operand sign bit. All signed coordinate differences are extended
before multiplication/subtraction; positive scores are compared as unsigned.

## Ports and transaction contract

All ports use one rising-edge `clk`. `rst` is synchronous active high and
overrides every phase, aborting partial capture, subdivision and held output.
There is **no CE**: every `valid && ready` at a rising edge is a transfer.
Use an explicit adapter with CE-qualified streams; clock gating is not provided.
Reset gates both public valid/ready low immediately, but state clears only at
the reset edge. Point/stack memories are not reset: a complete fresh capture
and stack initialization precede every read, so aborted data is never exposed.

| Port | Meaning |
|---|---|
| `s_x/s_y` | signed W-bit integer coordinate, no fractional bits |
| `s_valid/s_ready` | input token handshake; source holds the complete token while stalled |
| `s_keep` | append this coordinate if 1; a masked token still participates in framing |
| `s_last` | terminate the current polyline, including on a masked token |
| `s_epsilon` | unsigned W-bit coordinate-unit threshold; latched on the first accepted token only |
| `s_tag` | TAG_W-bit opaque tag; latched on the first accepted token only |
| `m_x/m_y` | unchanged selected input coordinate |
| `m_index` | zero-based ordinal among kept input points, not among masked/raw input tokens |
| `m_count` | total number of selected output vertices, repeated on every output |
| `m_first/m_last` | delimit output transaction; exactly one first and one last |
| `m_empty/m_error` | per-transaction empty/overflow status, repeated on every output |
| `m_tag` | first input token's tag, repeated on every output |

An all-masked transaction emits one `empty=1,error=0,count=0,index=0,x=y=0`
token with first=last=1. A one-point transaction emits that point once.
More than MAX_POINTS kept points latches overflow while continuing to consume
through `s_last`; it then emits **one** `empty=1,error=1,count=0,index=0,x=y=0`
token with first=last=1. No truncated/prefix simplified polyline is published.
Masked tokens do not consume capacity. There are no other runtime error codes,
SOF requirements, implicit restart, input-length timeout or external RAM errors.
An unterminated transaction requires the source to finish it or reset the core.

Capture accepts one token per clock, including gaps. Processing blocks all new
input; output is entirely buffered and never overlaps capture. `m_valid` and
**every output field** remain stable under arbitrary backpressure. The next
transaction may start on the clock after the final output handshake; no output
can be overwritten by a following input. Later input epsilon/tag values are
ignored, even if they differ from the first accepted masked token.

## Parameters, work and resources

| Parameter | Legal values | Default |
|---|---|---|
| COORD_W | 2..16 | 12 |
| MAX_POINTS | 1..64 | 32 |
| TAG_W | 1..32 | 8 |

IW=max(1,ceil(log2(MAX_POINTS))) bits hold output indices;
CW=ceil(log2(MAX_POINTS+1)) bits hold counts and stack addresses.
Illegal parameters terminate simulation at time zero; supported synthesis
configuration must honor these bounds. There is no runtime geometry change.

One signed MW x MW multiplier is physically expressed once in RTL and shared
by every square/product. A separate product register splits multiplication
from following additions/comparisons. Default is 27x27; maximum is 35x35, which
may require multiple FPGA DSP blocks. No DSP count or frequency is measured.
Two coordinate banks each have one scheduled synchronous read and one capture
write; capture and processing are disjoint. Stack endpoint banks have two writes
when pushing children and one read when popping. The small stack may map to
registers or distributed RAM; no BRAM inference claim is made.

Logical point+stack+bitmap storage is
`2*W*MAX_POINTS + 2*CW*MAX_POINTS + MAX_POINTS` bits: **1184** at defaults,
**3008** at maximum. Scalar arithmetic/control registers are additional.
This is a bounded contour/trajectory accelerator, not a one-pixel-per-clock
video frontend. Worst-case work is O(n^2), with O(n) storage. A nontrivial
segment with k interior vertices takes at most 13+14*k clocks; an adjacent
pair takes two. At most n-2 splits occur, and total examined interior vertices
is bounded by (n-1)*(n-2)/2. For n>=2, a conservative no-stall bound after
the final input handshake through final output transfer is
`4 + 4*n + 13*(n-2) + 2*(n-1) + 7*(n-1)*(n-2)` clocks.
Arbitrary output stalls add directly to completion time. Each selected vertex
needs scan/read, load and hold/transfer clocks; skipped bitmap positions add
one scan clock each. Frames do not overlap.

Architecture risk is **MEDIUM** at defaults and **HIGH** at maximum due to
the wide shared multiplier, stack write decode and worst-case quadratic work.
Storage is small but actual mapping, timing and power remain unknown. No vendor
primitive, external memory, generated coefficient or online dependency is used.

## Example and finite evidence

`example/contour_simplify_example.sv` is an ordered vertex frontend tying
`s_keep=1`; it exposes all selected-vertex metadata. `files.f` contains the
complete two-file offline RTL closure. A contour tracer must adapt its own
contour-end/coordinate convention and CE if present; this example does not
claim direct protocol compatibility with the older CE-qualified edge tracer.

Run `python -B cores/image_processing/polyline_rdp/run_tests.py` from the repo.
Each Icarus compile or simulation subprocess has a **20-second timeout**.
The oracle independently recurses on exact Python Fraction distances and checks
every output coordinate, original index, count, framing, status and tag.
Six simulated profiles cover all parameter extrema: 2/1/1, 2/8/1, 4/8/3,
8/16/8, 12/32/8 and 16/64/32 (W/capacity/tag). The extra 2/8/1 profile
exercises the full arithmetic at minimum coordinate width, separately from
the one-point capacity corner. The 4-bit profile includes all 729
ordered three-vertex paths on a signed 3x3 grid with varied thresholds.
Other cases include signed extremes, exact threshold equality, endpoint
projections, first-maximum ties, zero-length segments, closed/repeated paths,
full-capacity zigzags, masks, empty/overflow transactions, changing later
metadata, source gaps, multi-clock output stalls, and reset during capture,
multiply, projection, subdivision and held output. Six illegal-parameter
configurations are explicitly rejected. Temporary simulation artifacts are
automatically removed; bounded command results and seven content hashes remain
in `verification.json`.

Status: **LINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED** only
when supported by the adjacent generated evidence. Integration status denotes
the included frontend, not a full raster-contour-simplification pipeline.
No synthesis, PnR, STA, board test, full regression or physical PPA is run.

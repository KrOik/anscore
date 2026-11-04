# Exact convex hull of an unordered point stream

`point_convex_hull` computes the exact 2D convex hull of a small, arbitrarily
ordered signed-integer point set. It sorts and removes duplicates, then emits
only extreme vertices; collinear points lying between endpoints are excluded.
The first vertex is the lexicographically smallest signed `(x,y)`. Remaining
vertices have positive turns in the ordinary Cartesian convention (x right,
y up), so the polygon is counterclockwise and has positive shoelace area.
If coordinates use image y downward, that same vertex order appears clockwise
on a screen. The closing first vertex is **not repeated**.

One distinct input point gives one vertex. A fully collinear set with at least
two distinct points gives its two endpoints in lexicographic order. No selected
points gives an empty-result token. This is a point-set envelope computation,
not a contour trace, rectangle bbox, polygon rasterizer or image resampling
operation. Repository-wide searches found no equivalent hull core; existing
CCA/contour and geometry packages retain their separate functions unchanged.

## Point-stream contract

All activity uses a rising-edge `clk`. `rst` is synchronous active-high and
overrides reception, sorting, chain construction and pending vertices. Assert
it across a rising edge to cancel work. Ready and valid are gated low while
reset is asserted. Ownership/control resets; arrays and scratch arithmetic are
not reset. Every consumed array entry is written during the current point set
before use. There is no CE, CDC, external memory interface or bus-error channel.
A CE-qualified legacy stream needs a transfer adapter.

An input word transfers on `s_valid && s_ready`, carrying signed `s_x/s_y`,
`s_mask`, `s_last` and `s_tag`. Hold all fields stable while valid and not ready.
`s_mask=1` includes the point; zero excludes it. `s_last=1` ends the set even
if that word is excluded. The first accepted word's tag is retained, including
an excluded first word. Later tags are ignored. An empty set is represented by
one or more excluded words with last on the final one; no out-of-band empty
command exists. A missing last leaves capture open; reset restores alignment.

Input ready stays high through capture, allowing one word per clock. All
processing starts after last and blocks further input. At most MAX_POINTS
selected words are allowed, **before** duplicate removal. An additional selected
word latches overflow, and capture continues through last. No prefix hull is
published for an overflowed set: the result is one token with error=1, count=0,
empty=1, index=0, first=last=1 and x=y=0. Excluded words do not consume capacity.

Output vertices transfer on `m_valid && m_ready`. `m_count` repeats the total
number of vertices; `m_index` starts at zero; `m_first/m_last` mark the first
and final token. Coordinates, count, index, markers, error and tag remain
stable when output is stalled. Empty input returns the same zero-coordinate,
zero-count single token described above but with error=0. Thus empty means
there are no published vertices; inspect error to distinguish actual emptiness
from rejected geometry. Nonempty valid hulls have error=0 and empty=0.

Vertices can transfer every clock when the sink is ready. The next point set
can begin on the edge after the final result transfers. Output fields are
meaningful only when valid. There are no SOF/EOL raster markers or imposed
frame dimensions: a point set is the complete transaction. Pixel/feature
coordinate extraction belongs upstream. No runtime configuration updates occur;
parameters take effect only at elaboration.

| Parameter | Default | Legal range |
|---|---:|---|
| COORD_W | 16 | 2..24, two's-complement integer x and y |
| MAX_POINTS | 32 | 1..64 selected input words per set |
| TAG_W | 8 | 1..32 opaque unsigned bits |

`m_count/m_index` use `max(1,clog2(MAX_POINTS+1))` bits. Derived localparams are
internal. Simulation guards reject illegal public parameters. Coordinates use
their full signed range; there is no fractional scale, approximation, rounding,
saturation or coordinate-range rejection.

## Architecture, width and resource review

An insertion sort orders selected points by signed x then signed y. A compacting
scan removes adjacent duplicates. Lower and upper increasing-x/decreasing-x
chains use Andrew's monotone-chain criterion: remove a previous endpoint
whenever the exact turn is nonpositive. Lower-chain preservation is explicit
in the upper chain's pop threshold. The final repeated starting point is
removed from the published count. Empty, singleton and collinear outcomes
are handled without reading nonexistent neighbors.

Coordinate differences are explicitly sign-extended to `COORD_W+1` before
subtraction. The single shared multiplier computes the two signed cross-product
terms on separate clocks, retaining `2*(COORD_W+1)` product bits. Subtraction
uses another sign guard bit. The determinant sign is therefore exact over
the full signed coordinate domain, including opposite extremes. There is no
float, divide, tolerance-based turn test, magnitude approximation or wrapped
cross product.

Small bounded register arrays hold the sorted point set and chain workspace.
Their combinational indexed reads and shift writes are intentional; **BRAM
inference is not claimed**. Capacity is `2*MAX_POINTS*COORD_W` source bits and
`4*MAX_POINTS*COORD_W` chain bits, totaling 3072 bits by default and 9216 at
maximum parameters, plus scalar state/scratch and arithmetic registers.
None requires initialization data or a memory-clear sweep.

Insertion sorting has O(n^2) worst-case cycles; chain construction has O(n)
total pushes/pops. Each orientation takes two multiply clocks plus setup and
control work. Processing latency depends on point order, duplicates and hull
shape; input capture is II=1 and result output is II=1, with nonoverlapping
transactions. There is no continuous-video throughput promise or unconditional
completion deadline under arbitrary source/sink stalls.

Qualitative resource risk is **MEDIUM** at defaults and **HIGH** at the largest
register-array/coordinate profile pending target implementation checks. Array
read muxes, shift write enables, signed coordinate comparison, and the shared
up-to-25x25 multiply can dominate logic/timing. A multiply may map to DSP or
logic depending on target tools. The design uses no vendor primitive, external
storage or hard-IP dependency. Logical bit counts and cycle structure above
are architecture properties, not measured LUT/FF/DSP counts, frequency, power
or device-fit evidence.

## Offline use and finite validation

`files.f` lists the entire production dependency closure. No includes, ROMs,
coefficient files, generators or downloaded arithmetic modules are needed.
`example/feature_hull_example.sv` exposes the default coordinate/tag behavior
for feature point sets, masking all submitted points in.

```powershell
python -B cores/image_processing/point_convex_hull/run_tests.py
```

The runner uses Python's standard library and Icarus Verilog/vvp, preferring
the existing repository OSS CAD Suite and adding bin/lib to child PATH. Each
tool process has a strict 20-second timeout. A failed rerun removes the prior
PASS report. Generated deterministic TBs and simulator images live in a
task-specific temporary directory and are removed afterward. The complete TB
template, fixtures and independent oracle remain in `run_tests.py`; the
limited suite is fully offline.

Current maturity: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**.
`verification.json` records 23 actual bounded check results and binds five
source hashes. Five profiles (COORD_W/MAX_POINTS/TAG_W = 2/1/1, 4/3/3,
8/16/8, 16/32/8, 24/64/32) passed 672 sets and 2502 output tokens. All 512
subsets of a 3x3 signed coordinate lattice are included, with shuffled input
order. The acceptance oracle uses exact integer Jarvis gift wrapping rather
than the RTL's insertion sorting and lower/upper chain stacks. It compares
the entire ordered vertex sequence and all output metadata exactly.

Cases include signed-domain extrema, full-range rectangles, duplicate points,
collinear interiors, singleton/empty masks, ignored points, full-capacity
parabola hulls, overflow rejection and seeded arbitrary point lists. The
maximum parameter profile is actually simulated, including a 64-vertex hull
and 24-bit endpoint extremes. Protocol checks cover source gaps, blocked input,
first-tag capture, first/last/index/count, empty/error alignment, output stalls
on multiple vertices, reset during capture/sort/orientation/held output and
reuse without reset. COORD_W=1/25, MAX_POINTS=0/65 and TAG_W=0/33 are
separately rejected. This remains finite coverage, not an arbitrary-input or
all-parameter proof.

No synthesis, PnR, STA, board operation, full regression or hardware validation
was run. The minimal example is an **INTEGRATION_CANDIDATE**. All local text
uses LF to preserve evidence hashes in committed Git blobs. Fixed reference
and actual license review appear in [SOURCES.md](SOURCES.md).

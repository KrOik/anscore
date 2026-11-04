# Exact minimum-area oriented enclosing rectangle

`minimum_area_rectangle` encloses an unordered signed-integer point stream in
a closed rectangle of globally minimum Euclidean area. It returns an exact
integer projection encoding, not a sampled angle or rounded pixel box. This is
a bounding primitive for small feature/contour sets. It differs from the existing
point hull, minimum enclosing circle, raster maximum all-foreground rectangle,
polyline simplification and clipping against an already supplied ROI. Actual
repository-wide production/README searches and the relevant implementations'
contracts were read before development; none supplied this objective.

## Rectangle, center, corners and witnesses

Let `(dx,dy)=(m_axis_x,m_axis_y)`, `D=m_den`, and
`[u0,u1,v0,v1]=[m_u_min,m_u_max,m_v_min,m_v_max]`. Every successful rectangle is
the intersection of the exact closed strips

```
u0 <= x*dx+y*dy <= u1
v0 <= y*dx-x*dy <= v1
D = dx*dx+dy*dy > 0
area = m_area_num/D = (u1-u0)*(v1-v0)/D
```

For each choice `u in {u0,u1}`, `v in {v0,v1}`, the corresponding corner is
`((u*dx-v*dy)/D,(u*dy+v*dx)/D)`. In cyclic order use `(u0,v0),(u1,v0),
(u1,v1),(u0,v1)`. The center is
`(((u0+u1)*dx-(v0+v1)*dy)/(2D),((u0+u1)*dy+(v0+v1)*dx)/(2D))`.
These are exact rational encodings; numerators/denominators are not reduced.
The output axis has no unit-length normalization, fixed-point scale or angle
unit. There is no division, square root, trigonometry, tolerance or rounding in
the hardware. Consumers decoding corners/center must retain full intermediate
products and sums; the public widths are not a prescription for decoder widths.

Hardware enumerates retained input pairs `i<j` in lexicographic index order.
Coincident pairs are skipped. A direction is `Pj-Pi`, with both signs reversed
when necessary to make `dx>0` or `dx==0 && dy>0`. Each direction scans all points
for the four projection extrema, computes its area numerator and compares exact
areas by full cross multiplication. Only a strictly smaller area replaces the
winner. Equal areas retain the earliest input pair, including parallel/scaled
or perpendicular alternatives. Equal extrema retain the earliest point index.
Reordering inputs can change this encoding and witnesses while preserving the
minimum geometric area; minimum rectangles themselves need not be unique.

`m_pair_valid` identifies a nonzero generating pair `m_pair_i/m_pair_j`.
`m_u_min_index/m_u_max_index/m_v_min_index/m_v_max_index` witness points on the
four support lines. These indices are ordinals among retained points, including
duplicates, not among raw masked tokens. The generating pair need not be a hull
edge when multiple directions attain the same minimum. The extrema certify
containment/tightness; the exhaustive direction search supplies minimality.
Every nondegenerate minimum-area rectangle has a side parallel to a convex-hull
edge. Every such edge is one of the original point pairs, so the enumeration is
complete without sorting, a hull workspace or dynamic angular calipers.

All coincident input points use canonical axis `(1,0)`, D=1, u0=u1=x0,
v0=v1=y0, zero area and all witness indices zero; pair_valid=0 and dimension=0.
Distinct collinear points return a zero-area segment rectangle, pair_valid=1 and
dimension=1. Other successful results have dimension=2. Singleton, repeated,
horizontal, vertical, negative-direction, cocircular and equal-area sets are
ordinary legal inputs. There is no positive-width requirement.

## Transfer, errors and reset

All ports use one rising-edge clock, synchronous active-high `rst`, ordinary
ready/valid and no CE. A transfer is exactly `valid && ready` at an active edge.
A CE-qualified neighbor needs an explicit adapter. Signed W-bit `s_x/s_y` have
no fractional scale. `s_keep=1` appends a point, while masked tokens still carry
framing. Accepted `s_last=1` terminates the set even when masked. The first
accepted tag is retained, including a masked first token; later tags are ignored.
The source holds every token field stable while valid and blocked.

Capture accepts II1. The retained count `m_count` saturates at MAX_POINTS;
additional selected tokens latch overflow and drain through last. Status0 is
success, status1 an empty set, status2 overflow; status3 is unused. Empty and
overflow publish exactly one record whose axis, bounds, denominator, numerator,
dimension, pair_valid and six indices are all zero. Count and first tag remain
diagnostic. No prefix rectangle is published on overflow. Missing last leaves
capture open; the caller may finish or reset it. There is no raster SOF/EOL,
implicit restart, length timeout, external memory error or runtime configuration.

Processing and the held response block further input. All result fields remain
stable under arbitrary sink backpressure. Input may transfer on the clock after
output retirement. Only one transaction is owned at a time. Output fields are
meaningful while valid; best-result registers can change during processing.

Reset gates public ready/valid low while asserted, and its rising edge cancels
capture, reads, arithmetic and held output, clearing the complete public record.
The packed point RAM and arithmetic scratch are unreset. Only the current
captured prefix is read, every candidate reloads its anchors, and each multiply
initializes all of its live state. Canceled work cannot supply geometry to a
fresh transaction. There is no CDC, vendor primitive or implicit clock gating.

## Width, resource and cycle review

Parameters W=COORD_W 2..12 (default8), M=MAX_POINTS 1..8 (default8),
T=TAG_W 1..32 (default8) are static; named elaboration guards reject invalid
profiles. IW=max(1,clog2(M)), CW=max(1,clog2(M+1)), MW=4W+4,
RW=2MW, BW=max(1,clog2(MW)). Axes and projection bounds are signed MW;
denominator and area numerator are unsigned MW; count is CW and indices IW.

Let B=2^W-1 and H=2^(W-1). Signed coordinate magnitude is at most H, including
the minimum negative value. Differences are extended before subtraction and
have magnitude <=B. Absolute projections are <=2HB<2^(2W); projection spans
are <=2B^2<2^(2W+1), as is D. Area numerator is <=4B^4<2^(4W+2).
Its cross multiplication by another D is <=8B^6<2^(6W+3). All projection,
norm and area intermediates fit the signed MW magnitude limit 2^(4W+3), and
both compared products fit the complete unsigned RW width 2^(8W+8).
There is no wrapped/truncated area comparison, saturation or supported-domain
numeric overflow. Full signed MW products are retained before mathematically
safe low-MW selections; comparison products remain at RW throughout.

One fixed-MW-step signed-magnitude shift/add engine performs all products.
There are no parallel `*` or `/` operators in production RTL. A registered-read
packed point RAM holds `2WM` logical bits, 128 default and192 maximum. Capture
and reads are disjoint; read addresses always name a freshly written entry.
No RAM reset or initialization file is needed. Physical block-RAM mapping is
not guaranteed for this small capacity.

All scalar storage, including RAM read data, output/best fields and multiplier
scratch, is exactly `29MW+4W+CW+13IW+BW+14+T` logical bits:1147 default and
1651 maximum. Including point RAM gives1275/1843 bits. The29MW term is20MW
algorithm/output state,7MW multiplier state and2MW saved cross product.
The remaining terms include read/anchor coordinates, count, thirteen indices,
multiplier step,4-bit state,4-bit operation, status and four one-bit controls.
These are source-level storage counts, not synthesized FF/LUT/DSP/BRAM results.
Architecture risk is LOW at the declared bounded sizes; the broad shared
operand mux, MW-bit add and RW-bit compare are expected paths, without measured
frequency, timing, power or implementation evidence.

Measured in active edges from accepted last to first valid, errors take0 edges,
and a singleton takes2. For n>1 there are C(n,2) pair candidates. A coincident
pair consumes5 edges and two RAM reads. A nonzero pair uses two norm products,
four per-point projection products, one area product and, after the first such
pair, two area-comparison products. Each multiply uses MW+2 edges including
launch and result dispatch. That pair consumes
`6+2n+products*(MW+2)` edges and `2+n` reads. Initial point0 loading costs2
edges/one read. Thus a conservative full tail bound is
`2+C(n,2)*(6+2n+(4n+5)*(MW+2))`:39986 default and56562 maximum.
The first direction omits two comparisons; actual exact work is fixture-bound.
No unconditional complete transaction deadline exists with unbounded source
gaps or sink stalls. These are RTL schedule counts, not board throughput.

## Offline closure and bounded verification

`files.f` lists the single production source. Compile the independent wiring
example with that source and `example/minimum_area_rectangle_example.sv`.
There are no external HDL dependencies, generated coefficients, network runtime,
vendor libraries or required inherited tools. Testbench/Python are verification
assets, not part of the hardware closure.

The authoritative validation state and raw child receipts are in
`verification.json`; hardware remains HW_UNVERIFIED. `TEST_PLAN.json` freezes
the finite matrix and exact source/fixture hashes before the first HDL child.
No synthesis, PnR, STA, board check, expanded regression or inherited rerun is
authorized by this package. Each compiler/simulator child has a20-second terminal
timeout: a timeout must not be retried, shrunk or given a larger limit. An ordinary
failure requires preserved historical receipts and repair on the unchanged matrix.

The five numeric profiles are W/M/T=2/1/1,2/3/3,4/4/8,8/8/8,12/8/32;
the maximum profile runs actual full-range coordinates. Six named negative
profiles reject W1,W13,M0,M9,T0,T33. Directed extrema, duplicate/collinear and
degenerate sets, exhaustive capacity-compatible2x2-grid subsets and seeded
full-domain random sets use an exact Fraction oracle. Primary minimization
builds an independent monotone hull and considers only hull edges. A separate
pass selects the public first-source-pair representation matching that minimum;
generic rational Gaussian elimination independently audits corners and center.
Floating tolerances and upstream execution are absent.

The TB compares every public field, exact product/step/read/pair/tail counts,
fresh RAM ownership and every completed full signed multiply. It verifies real
next-fixture preoffers remain stable through actual queued acceptance, input
gaps/consecutive II1 beats, full output holds, errors and no extra results.
Reset probes assert reset immediately at observed capture/read/compute/output
states; every multiplier operation is interrupted at launch, first/middle/last
iteration and dispatch. Every reset is followed by a complete analytic triangle
result (singleton for capacity1), exact work, all fields, hold, retirement and
no-stale check. The raw fixture loader uses scalar fscanf temporaries from its
first version, avoiding dynamic memory-lvalue loader constructs.

Owner-only commands: `python run_tests.py --prepare` freezes fixtures/plan;
`python run_tests.py --run` executes only that matrix. Preparation is not an HDL
result. Cross-review reads frozen evidence without invoking these commands.

The first version-query child selected an already installed but broken
Chocolatey PATH shim and failed normally in0.281seconds; no RTL compiler work
had occurred and no timeout occurred. `history/attempt_01.json` preserves the
exact initial plan, raw failed receipt and original runner text with hashes.
The resolver was repaired to prefer the existing workspace OSS CAD Suite
binary and prepend its bin/lib directories to the child PATH. Profiles,
fixtures, child matrix and20-second policy were unchanged.
The current plan records the ordinary repair and the final receipt retains its
history binding; that original failure is not relabeled as a passing check.

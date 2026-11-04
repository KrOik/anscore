# Exact minimum enclosing circle of a point stream

`minimum_enclosing_circle` computes the unique minimum-radius closed Euclidean
circle containing an unordered signed-integer2-D point list. It returns a rational
center and squared radius, plus deterministic support indices. This is a spatial
bounding primitive for small feature/contour sets, distinct from ring-vote Hough
detection, raster moments, point hull, polyline simplification/matching and ROI
segment clipping. Actual tracked and untracked production searches found no
equivalent enclosing-circle service. No old RTL is modified or linked.

## Exact circle and support certificate

The normal center is `(m_center_x_num/m_den,m_center_y_num/m_den)` and squared
radius is `m_radius_sq_num/(m_den*m_den)`. The denominator is strictly positive;
fractions are not reduced. There is no fixed point, square root, tolerance,
rounding, floating point, resampling or host-side circle computation.

Every finite nonempty point set has a minimum circle supported by one point,
a diameter pair, or a nonobtuse triangle's circumcircle. The center lies in the
convex hull of its boundary support, so any such circle containing all points
is already globally minimal. Hardware tests point0's radius-zero singleton,
then all index pairs i<j in lexicographic order, then all triples i<j<k in
lexicographic order. It returns the first containing certified candidate. There
is no heuristic radius search or comparison of approximate candidate radii.

For triangle A,B,C, define U=B-A,V=C-A, nu=U dot U,nv=V dot V,t=U dot V.
All angles are nonobtuse exactly when `0<=t<=nu` and `t<=nv`. Collinear triples
are rejected. Let `D=2*cross(U,V)`, `rx=nu*Vy-nv*Uy`,
`ry=Ux*nv-Vx*nu`. Before sign normalization the center numerators are
`Ax*D+rx,Ay*D+ry` and radius numerator is `rx^2+ry^2`. If D<0, negate
D,rx,ry and both center numerators. Containment tests exact
`((Px-Ax)*D-rx)^2+((Py-Ay)*D-ry)^2 <= radius_num`.
For a pair, D=2,rx=Bx-Ax,ry=By-Ay, center numerators are A+B.
For the singleton D=1, center is point0 and radius numerator zero.

Repeated/coincident points retain separate input ordinals. All coincident points
select support1/index0. Collinear sets select a diameter pair; a right triangle
also selects its hypotenuse pair before the triple phase. Successful support3
therefore has an acute triangle. Cocircular alternatives use the first qualifying
support in the search order, not lexicographic coordinates. Reordering input may
change support indices and unreduced encoding, but preserves the geometric circle.
Unused support indices are zero; support2 uses i,j and support3 uses i,j,k.

## Transfer, errors and reset

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid and
no CE. Every `valid && ready` edge transfers. A legacy CE-qualified stream needs
an explicit transfer adapter. `s_x/s_y` are signed W-bit integers. `s_keep=1`
appends a point; masked tokens consume no capacity but still participate in
framing. Accepted `s_last=1` ends the transaction even when masked. The first
accepted tag is retained, including a first masked token; later tags are ignored.
Source holds **all** token fields stable while valid and blocked. A missing last
leaves capture open until the caller finishes or resets it.

`m_count` is the retained selected count, saturating at MAX_POINTS. Additional
selected tokens latch overflow while input continues through last. Status0 is
success,1 empty input,2 overflow. Empty and overflow return one held response
with center/denominator/radius/support/indices all zero, retaining count and tag.
No prefix circle is published on overflow. Reserved status3 is finite search
exhaustion; the support theorem makes it unreachable for supported legal input.
Normal support is1/2/3 and count>0. Every response is one complete record; there
is no raster marker or output path stream.

Capture accepts II1. Processing and held response block all input. Every output
field remains stable while valid and not ready. The next transaction may transfer
on the edge after result retirement. No configuration changes, external RAM,
bus errors, CDC or input-length watchdog are implicit. Source gaps and sink
backpressure may be unbounded.

Reset gates public ready/valid low immediately, cancels ownership at its rising
edge and clears all public fields. It overrides all arithmetic and output hold.
The packed point RAM is unreset; every consumed entry belongs to the current
retained prefix, written before processing. Every candidate reloads its anchors,
constructs its circle, and initializes each multiplier. An aborted transaction
cannot supply points or scratch state to the next one.

## Whole-domain width and structural review

Parameters: COORD_W W=2..12(default8), MAX_POINTS M=1..8(default8),
TAG_W=1..32(default8). Illegal parameters receive a named elaboration rejection.
IW=max(1,clog2(M)), CW=max(1,clog2(M+1)), MW=3W+5, RW=2MW.
Public center numerators are signed MW; denominator unsigned MW; radius numerator
unsigned RW. A full signed MW-by-MW product is retained in RW bits.

Let B=2^W-1. Coordinate differences are explicitly extended to signed W+1 before
subtraction, then to MW, including opposite signed extrema. Norms and |dot| are
at most2B²<2^(2W+1); |cross|<=2B², |D|<=4B²<2^(2W+2).
|rx|,|ry|<=4B³<2^(3W+2). A signed coordinate has magnitude <=2^(W-1),
including the minimum negative input. Thus absolute center numerators are below
2^(3W+3), and containment differences are <=8B³<2^(3W+3). These fit signed
MW, whose magnitude limit is2^(3W+4). Radius numerator is <=32B^6<2^(6W+5);
containment squared sum is <=128B^6<2^(6W+7), below even the signed RW limit
2^(6W+9). All low-MW product selections and sign restorations therefore retain
the complete legal values. There is no numeric overflow or saturation.

One unsigned magnitude shift-add engine with a separate sign performs every
square/product in exactly MW steps; final-bit accumulation is explicit. Operand
setup and result storage each add an edge. No runtime `*` or `/`, combinational
candidate bank, primitive, coefficient image or reset RAM sweep is present.
Construction separates multiply results from later decisions. One packed2W-bit
RAM has one scheduled synchronous read, disjoint from capture writes.

Logical RAM is2WM bits:128 default/192 maximum. Sequential scalar bits, including
unreset read data and all public fields, are
`34*MW+6*W+19+7*IW+BW+CW+TAG_W`, BW=max(1,clog2(MW)):
1091 default/1548 maximum. Combined logical stored bits are1219/1740.
These counts are architecture properties, not mapped FF/BRAM/LUT measurements.
Risk is LOW default/MEDIUM maximum due to RW-wide add/negate/compare paths and
bounded serial work. Actual mapping, timing, power and device fit are unknown.

At most C=1+choose(n,2)+choose(n,3)<=85 candidates are visited. A candidate
needs at most16 products to construct and4 products per containment point,
with early geometric rejection and first-outside rejection. A conservative
first-valid tail is `2+C*(8+(16+4*n)*(MW+2)+3*n)` periods after accepted last.
Errors take exactly1. The singleton n1 tail is exactly9+4*(MW+2).
The analytic acute triple[(-1,-1),(1,-1),(0,1)] takes64+66*(MW+2), returning
center(0,-2)/8 and radius numerator100 over64. Response transfer adds an edge;
arbitrary stalls add directly. This is a bounded point-set accelerator, not a
continuous-video or fixed-frequency service claim.

## Offline closure and finite evidence

`files.f` contains one production RTL source; `example/files.f` adds the default
`feature_circle` frontend exposing all fields. No includes, ROMs, generated
assets, sibling sources, packages or network are needed. The original Fraction
oracle uses recursive Welzl boundary-set recursion and Gaussian perpendicular-
bisector solves, not the hardware's exhaustive support scan. It independently
certifies all points enclosed and exact support-circle equality. The TB checks
complete packed outputs, exact candidate/work/first-valid counts, every current-
prefix RAM read and full signed multiplication, stalls, reset and actual queued
transaction acceptance. Fixed source/license inspection is in SOURCES.md.

`TEST_PLAN.json` freezes five numerical W/M/T profiles2/1/1,2/4/3,4/8/8,
8/8/8 and maximum12/8/32. It includes all256 subsets of an eight-point2x4
grid, all64 ordered triples on a signed2x2 grid and all27 ordered triples on
an acute three-point domain. Signed extrema, opposite orientations, collinear,
right/obtuse/acute/cocircular/coincident sets, duplicates, empty/overflow,
first masked tags, changed later tags, source gaps and II1 are included.
Each observed reset phase is canceled before another active edge, followed by
a complete analytic fresh record, exact latency, hold, retirement and no stale
output. Capacity1 skips impossible outside/NEXT phases and aliases angle-check
to point-check. Held normal/empty/overflow reset probes offer a stable blocked
source canceled only by reset. An additional actual queued singleton is retained
through prior-result retirement and accepted on the following edge.

Run `python -B cores/image_processing/minimum_enclosing_circle/run_tests.py`.
Exactly19 children are planned: version, core/example syntax, five compile/sim
pairs and six named rejects. Every compiler/simulator child has a strict20-second
limit. TIMEOUT is terminal: no retry, fixture shrink or increased limit. Ordinary
failures remain embedded before a fixed-matrix correction. Temporary artifacts
are automatically removed; all sources and deterministic fixtures remain offline.
Local text is strict UTF8/LF from inception. Current evidence records all19
first-attempt children PASS, with no failures/timeouts:529 frames,2900 tokens,
2489 candidates,6299 containment checks,616956 multiply steps,13766 RAM
read checks,31740 full signed-product checks,1925 consecutive accepted II1
checks and529 exact first latencies.108 immediate reset probes each passed
the full analytic fresh recovery, and all five queued singleton checks passed.
Support counts are53 singletons,371 pairs and90 triangles;318 results have
fractional centers/radius-squared. Coverage includes75 negative-orientation
candidates,136 obtuse and8 collinear rejects,2515 held cycles and65 blocked
source cycles within the exact reset/queue scope above. Every non-singleton
profile reached all16 states; capacity1 excludes angle-check and NEXT.

Before the first HDL tool, the raw-token TB loader was proactively changed to
scalar parse temporaries, following static review of the known B17 Icarus issue.
That was not a compiler failure or a qualification rerun; the frozen plan and
fixtures were unchanged. After PASS only this evidence paragraph and report
packaging changed. The report retains the prior PASS SHA, old/new README hashes
and nine unchanged source hashes; no tool or oracle was rerun for that refresh.

Maturity: LINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED.
No synthesis, PnR, STA, board, expanded regression or PPA is run.

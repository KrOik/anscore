# Exact point-set Delaunay triangulation

`point_delaunay` builds a complete planar Delaunay mesh from a real unordered
signed-integer point cloud. It retains every distinct input point, including
points inside the convex hull and collinear points on its boundary. Repeated
coordinates use their first retained input ordinal. Each triangle reports its
three original retained ordinals and original coordinates, with positive
Cartesian signed area. No sorting, hull, topology or triangulation is supplied
by a host. This is a bounded serial feature-mesh service.

The existing `polygon_triangulation` partitions one supplied ordered simple
polygon, including concavities. This service discovers the convex-hull domain
and connects arbitrary interior points under the empty-circle criterion.
`point_convex_hull` discards interior/boundary-collinear points and cannot act as
a transparent frontend. Enclosing circles/rectangles return bounding primitives.
The contour tracer emits CE-qualified directed cell edges, with unsigned image
coordinates and potentially multiple/self-touching loops. Those contracts need
explicit extraction, coordinate and transfer adapters. No neighbor is modified
or implicitly connected. The example exposes this complete standalone service.

## Geometry and deterministic degeneracies

Let U be the number of distinct points. All coordinates use their complete
two's-complement integer domain, without rounding or tolerance. For U>=3 and
noncollinear input, success returns a complete straight-line triangulation of
the convex hull, using every distinct point. Every open triangle circumdisk is
empty. A point exactly on a circumcircle is handled by the single global rule
below. Output candidates are enumerated as retained indices i<j<k, in that
lexicographic order. A negative turn swaps the last two output indices, so the
first index is always the triangle's smallest ordinal and area is positive.

Use the conceptual lifted height
`z_r=x_r^2+y_r^2-epsilon^(r+1)`, where
`epsilon=2^(-(2*COORD_W+5))`. The mesh is the lower convex-hull triangulation
of these heights. The hardware stores neither epsilon nor lifted coordinates.
For a nonzero integer incircle determinant its original sign is preserved.
For a zero determinant the negative height cofactor of the smallest of the four
retained ordinals supplies the sign. With candidate i<j<k and other point p,
the zero case rejects if p<i, otherwise it uses `-orient(j,k,p)` as the
incircle sign. Comparison to `orient(i,j,k)` is sign-only. This is one globally
consistent perturbation: each maximal empty cocircular face is a fan from its
smallest original ordinal. It does not independently choose arbitrary diagonals.
Input reordering may select different valid cocircular diagonals.

For completeness, put B=2^C-1. Every height cofactor has magnitude <=2B^2.
Nonzero integer determinants have magnitude >=1, while all perturbation terms
sum to <=2B^2*epsilon/(1-epsilon)<1. In a zero determinant the first nonzero
cofactor is an integer of magnitude >=1 and dominates its later terms.
Four distinct cocircular points with a noncollinear defining triple have no
collinear triple, so that first cofactor is nonzero. Each original point remains
a lower-hull vertex: its paraboloid tangent plane has gap equal to the positive
squared distance (>=1) to any other distinct integer point; the small height
changes cannot close that gap. Hence the lower faces form a complete planar mesh
using all distinct points. With h boundary vertices, including collinear
subdivisions, Euler gives T=2U-2-h<=2U-5. This proves the triangle-bank capacity.

Zero selected points, one unique point and any fully collinear set are legal.
They return one zero-payload summary token with count0/has_triangle0/error0.
`m_unique` distinguishes emptiness; dimension0 means U<=1, dimension1 means
U>=2 and collinear, dimension2 means a genuine mesh. Duplicate ordinals never
appear in a mesh, but `m_points` counts all retained selected words, before
deduplication. Forward boundary-collinear points remain vertices of the mesh.

## Transfer and ownership

One rising-edge clock, synchronous active-high reset, ordinary ready/valid and
no CE. Every valid&&ready edge transfers. Hold every source field while valid
and blocked. `s_keep` includes a point; masked tokens still carry framing and
upstream errors. Accepted `s_last` ends the set even when masked. The first
accepted tag is retained even if masked; later tags are ignored. Missing last
leaves capture open until the source completes or resets.

Input accepts II1 through capture. Capacity counts selected words before
deduplication. Additional selected words latch error bit0 and drain through last.
Any accepted `s_error` latches bit1. External errors skip geometry and return one
zero-payload token: unique/count/index/dimension/has_triangle0, first=last=1,
with the retained saturated point count, errors and first tag. No prefix mesh is
published. Bit2 is an internal capacity invariant failure, unreachable for the
supported domain by the lower-hull/Euler proof; it also suppresses the mesh.

The full mesh is buffered before any successful triangle appears. Every record
repeats `m_points/m_unique/m_count/m_dimension/m_error/m_tag`; m_index begins at
zero, m_first and m_last mark its ends. All fields stay stable under arbitrary
output stalls. A normal empty/point/line summary follows the same hold/retirement
rules. Processing and output block all further input until the final retirement;
the real next input may be accepted on the following edge. Replay takes eleven
edges from a triangle retirement to the next post-edge valid (twelve between
unstalled retirement edges). There is no output-ready to input-ready path.

Reset immediately gates ready, valid, has_triangle and first/last low. Its active
edge cancels capture, arithmetic, reads or a held record. It clears public
ownership/count/error/tag/coordinate/ID registers. Banks and read-q are unreset;
only the current written retained prefix and current mesh may be consumed.
The live bitmap is written over that entire prefix before deduplication. Every
load, difference and arithmetic result is initialized before its consuming job.
No canceled response is emitted. A receiver discards any partially received mesh
on reset. No CDC, external RAM, runtime configuration or implicit abort exists.

| Parameter | Default | Legal |
|---|---:|---:|
| COORD_W C | 8 | 2..12 |
| MAX_POINTS N | 8 | 1..16 |
| TAG_W | 8 | 1..32 |

IW=max(1,clog2(N)), CW=max(1,clog2(N+1)),
TM=max(1,2N-5), TCW=max(1,clog2(TM+1)). IDs use IW;
point/unique counts CW; triangle count/index TCW. Illegal values fail with the
named `point_delaunay_invalid_parameters__see_README` elaboration guard.

## Datapath, clocked storage and cycle budget

Three unreset single-port logical banks store x, y and packed triangle IDs.
A coordinate load reads both coordinate banks on one edge, then latches its
selected A/B/C/P slot on the next edge. Triangle replay likewise uses an
explicit registered read before decoding IDs and loading its three vertices.
There are no asynchronous bank reads, clear sweeps or multiple same-bank ports.
Logical RAM is `2CN+3*IW*TM`:227 bits default and708 bits at maximum parameters.
These are source bits, without a claim about physical BRAM packing.

One signed shared multiply expression serves all geometry. Differences are C+1
bits; a square/difference-factor product retains2C+2. Squared-distance lifts use
unsigned2C+1, extended with a leading zero to signed2C+2. Cross products retain
signed2C+3. The shared operands are signed(2C+3) by signed(2C+2), retaining
4C+5 product bits. A separate signed4C+7 accumulator sums the three incircle
terms. For |difference|<=B, lift<=2B^2, |cross|<=2B^2 and |D|<=12B^4;
all widths cover opposite signed endpoints and intermediate signs. Product
formation and consumption use separate edges. There is no data divide,
remainder, square root, floating point or vendor primitive.

Deduplication scans pairs and clears later equal ordinals. Hardware then
enumerates all retained triples, rejects collinear ones and scans every other
live point for the incircle predicate. Early rejection is permitted; no search
limit changes the result. Orientation uses two multiply jobs. Each incircle
uses fifteen multiply jobs: for each cyclic term, two squares, two cross-product
factors and one lift-times-cross. These take thirty product/consume edges.
An eligible query costs35 edges including dispatch, clocked load, differences
and evaluation. A full triple costs at most35N-85 edges, including its three
skipped anchor queries, store and combination advance. The27-state FSM and all
register groups are recorded in ARCHITECTURE.json.

Including all read-q, public and private clocked scalars, the exact declared
budget is `30C+11IW+2CW+2TCW+TAG_W+N+49`:354 bits default and521 at maximum.
Combinational multiplier operand selection is excluded; no clocked register is
excluded. Full no-stall tail completion is conservatively bounded by
`32+8N+6*choose(N,2)+choose(N,3)*(35N-85)+12*TM` (the triple term is zero
for N<3):11,316 default and267,204 at N16. Source gaps and output stalls add
their actual cycles. These are architecture budgets, not measured PPA or video
throughput. Qualitative risk is MEDIUM: the up-to27x26 multiplier and wide
incircle add/compare need target implementation checks. No synthesis, PnR,
STA, board or inherited regression is part of this package's evidence.

## Frozen finite validation

MATRIX.json and all inputs/golden records were written before RTL. The original
oracle constructs Fraction circumcentres/radii, groups all empty circles,
gift-wraps their boundaries and fans from their smallest ordinal. It does not
use the RTL's translated incircle calculation. Certificates require every
distinct point, positive triangle area, exact oriented boundary/internal-edge
multiplicities, all hull subdivisions, Euler/capacity equality and exact zero
interior overlap by rational triangle clipping. No floating-point upstream
triangulator is the acceptance oracle.

Five actual profiles cover2/1/1,2/3/3,3/4/8,8/8/8,12/16/32. Frozen7929 main
sets include all729 ordered3x3-lattice triples with replacement, all6561 ordered
quadruples with replacement, all511 grid subsets of at most8 points, signed
extrema, full-capacity meshes, 12 cocircular points, interior/boundary collinearity,
duplicate first-ID behavior, masks and all external errors. The maximum fresh
set contains16 distinct points and27 triangles, attaining bank capacity.

Fifty-nine explicit reset targets cover every FSM state, all15 incircle returns,
both orientation returns, all determinant/tie branches, duplicate clearing and
held empty/point/line/error/mesh results. N1 explicitly excludes49 unreachable
targets and N3 excludes22. Each of224 actual reset probes asserts immediately
at the first post-edge observed boundary, without an intervening active edge,
then completes a full-capacity fresh transaction. Every fresh output is held
at least three cycles and retired. The TB checks all public fields, actual next
frozen tokens, whole-field holds, exact products/orientations/incircles and every
clocked read against current-owner shadow banks. It checks all main/fresh
first-valid latencies against the paper bound.

`python run_tests.py --freeze-source` binds all sources before the first HDL
child; `--run` executes exactly121 pre-split children, each with a hard20-second
limit. TIMEOUT terminates the matrix without retries, reductions or a longer
limit. Ordinary failure preserves every source/plan/receipt and NOT_RUN list
before root authorizes repair. A successful receipt is immutable. `--audit`
checks its source/fixture/record closure offline. Actual maturity and executed
counts appear only in verification.json. Hardware remains HW_UNVERIFIED.

# Exact rational grayscale isocontour graph

`grayscale_isocontour` converts an actual unsigned grayscale raster into all
marching-squares line segments at a captured half-integer level. Exact rational
edge intersections and a data-dependent bilinear asymptotic decider preserve
subpixel edge positions and a consistent branch topology. No host-generated
edges, thresholded mask, precomputed graph or expected result is an input.

Baseline: `b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333`. Actual finite qualification
and every raw child disposition are in `verification.json`. The source is always
HW_UNVERIFIED: no synthesis, mapping, PnR, STA, board, frequency, power or fit
evidence is produced. A sealed plan alone does not establish a passing check.

## Scalar field, exact nodes and branch topology

WIDTH by HEIGHT samples occupy integer coordinates x=0..WIDTH-1,
y=0..HEIGHT-1, with y increasing downwards. Each adjacent 2x2 sample cell is
visited by upper-left coordinate in row-major order. WIDTH1 or HEIGHT1 is legal
and has no 2D cells. Samples outside the raster do not exist. There is no padding,
mask, keep input, ROI, corner equality, interpolation rounding or tolerance.

An unsigned PIXEL_W-bit `s_level=t` represents the actual scalar level t+1/2.
Every input encoding is legal. The largest level is above all representable
samples and gives an empty graph. For corners a=(x,y), b=(x+1,y),
c=(x+1,y+1), d=(x,y+1), define L=2t+1 and signed deviations
z0=2a-L, z1=2b-L, z2=2c-L, z3=2d-L. These are nonzero odd integers.
An edge crosses exactly when its two deviations have different signs.

Local edge IDs and their **canonical** origins/directions are:

|ID|axis|base coordinate|origin -> other|
|---|---:|---|---|
|0 top|0|(x,y)|a -> b, increasing x|
|1 right|1|(x+1,y)|b -> c, increasing y|
|2 bottom|0|(x,y+1)|d -> c, increasing x|
|3 left|1|(x,y)|a -> d, increasing y|

Each endpoint is `(axis,base_x,base_y,num,den)`, with
`num=abs(origin deviation)` and `den=abs(origin deviation)+abs(other deviation)`.
Its coordinate is `(base_x+num/den,base_y)` for axis0, or
`(base_x,base_y+num/den)` for axis1. Every segment endpoint has 0<num<den.
Fractions are **not reduced**: den is exactly 2*abs(other_gray-origin_gray).
The node's global grid-edge ID is `(axis,base_x,base_y)`; neighboring cells
produce bit-identical IDs, numerators and denominators for their shared edge.
This representation needs no division or multiplied global rational coordinate.

A cell has0,2 or4 crossings. Zero emits nothing. Two emits their unique pair.
Four uses the full signed determinant Q=z0*z2-z1*z3:

|Condition|Pairs of local edge IDs, in emitted order|
|---|---|
|Q>0|(0,1), then (2,3)|
|Q<0|(0,3), then (1,2)|
|Q=0 and z0>0|(0,3), then (1,2)|
|Q=0 and z0<0|(0,1), then (2,3)|

Within a pair the lower edge ID comes first; the two pairs are sorted by their
first edge ID. This orders segments deterministically without giving them a
contour orientation. In alternating cells the bilinear mixed coefficient
A=z0+z2-z1-z3 has the sign of z0, and the saddle value is Q/A. At Q0 a single
positive level perturbation disconnects the high-valued regions everywhere.
In doubled coordinates raising L by delta gives Q(delta)=Q-delta*A. One common
delta=2^(-(PIXEL_W+4)) preserves all corner signs and all nonzero Q signs:
abs(A)<2^(PIXEL_W+3), while a nonzero Q is an even integer of magnitude>=2.
At Q0 it selects exactly the table above. Endpoint fractions use the original
level's delta->0 limits. This is a globally consistent regularization, not an
arbitrary per-cell tie or the literal X-shaped unregularized critical level set.

The output geometry consists of **straight chords between exact interpolated
endpoints**. Chords are not claimed to equal curved bilinear isolines. Every
interior crossing grid-edge node has degree2; boundary crossing nodes have
degree1. The selected chords do not cross inside a cell. Thus the complete
undirected graph represents paths and cycles. Global contour ordering, loop IDs,
holes, signed area, polygon tessellation and vertex tracing are outside this
core's contract. Existing binary unit-cell ordered contours are a different
representation and capability.

## Frame ownership, held output and cancellation

All ports share one rising-edge clock and synchronous active-high reset. There
is ordinary ready/valid and no CE or CDC. Transfer occurs on valid&&ready.
All source fields remain stable while valid&&!ready. Static WIDTH*HEIGHT=N
accepted pixels define exactly one row-major raster. SOF is required only at
pixel0, and EOL only at each real row end. There is no LAST input, restart on
unexpected SOF, resynchronization scan or missing-tail timeout. Supply the
remaining N pixels or reset a partial frame.

The **first accepted pixel** captures `s_level` and `s_tag`, even if malformed.
Later level/tag changes are ignored. All accepted pixels contribute independent
sticky errors: bit0 SOF mismatch, bit1 EOL mismatch, bit2 upstream `s_error`.
Errors do not shorten capture or steal ownership. No output escapes until the
complete fixed raster has been received and all errors are known. Any error
skips every cell read and multiply and emits just one summary with zero endpoint
payload and index0, the first tag, and all accumulated errors. Bad frames never
produce provisional graph fragments.

There is one output RV stream. Each segment has `m_is_summary=0`, both endpoint
records, zero-based `m_index`, captured tag and zero errors. Exactly one final
summary follows: `m_is_summary=m_last=1`, endpoints all zero, and `m_index` equal
to the total number of segments. Summary is mandatory even for an empty or
rejected frame. `m_first` is true whenever index0, so a lone empty/error summary
is both first and last. `m_last` is true only on the summary. First/last/summary
are gated by valid; other fields are meaningful while valid. Every public field
and valid remains stable during arbitrary output backpressure.

The current frame owns the core through summary acceptance. No next-frame pixel
can transfer on that same edge. A waiting next pixel can transfer on the next
rising edge. Input capture has II1 when valid is continuous; source gaps are
legal. There is no input/processing/output frame overlap and no bound on elapsed
time with unlimited source gaps or sink stalls.

Reset immediately gates ready, valid, first, last and summary low. Its active
edge cancels any capture/read/arithmetic/segment/summary ownership and clears
all control, captured configuration, deviations, products and public payload.
RAM and its clocked read-q remain unreset. A new frame overwrites all N entries
before processing; every corner load reads before latching its deviation.
Receivers discard any transferred graph prefix when reset cancels a frame.

## Widths, memory and finite service budget

|Parameter|Default|Legal domain|
|---|---:|---|
|WIDTH / HEIGHT|16 /16|Each1..64|
|PIXEL_W=G|8|1..12, all grayscale input bits used|
|TAG_W=T|8|1..32|

Let X=max(1,clog2 WIDTH), Y=max(1,clog2 HEIGHT),
A=max(1,clog2 N), C=(WIDTH-1)*(HEIGHT-1), and
S=max(1,clog2(2C+1)). S represents the maximum segment count2C exactly,
including the final summary index. Endpoint bases require only X/Y bits because
coordinates stop at WIDTH-1/HEIGHT-1. Deviations use signed G+2 bits; absolute
magnitudes, num and den use unsigned G+1. Den<=2^(G+1)-2. The sole shared
(G+2)*(G+2) signed multiplier keeps a full signed2G+4 product and a first-product
register. A combinational signed2G+5 subtraction compares Q without truncation.
Default/max multipliers are10x10 /14x14, with20/28-bit products and21/29-bit Q.

One unreset single-port, synchronous-read RAM stores G*N bits:
**2,048 default /49,152 maximum**. Reads and writes never overlap. Capture and
cell traversal share address/x/y cursors because their lifetimes are disjoint.
Four signed deviations retain corners through both possible segment retirements.
There is no graph RAM, external memory, vendor primitive, ROM or data divider.

Declared scalar/read/public storage is exactly `14G+3X+3Y+A+S+T+41`:
**202 default /302 maximum bits**. This includes read-q G, deviations4(G+2),
two products2(2G+4), phase-shared cursor A+X+Y, state4, load-slot2, edge IDs8,
pair flags2, segment count S, level G, tag T, errors3, and endpoint output
2X+2Y+2+4(G+1). Combinational wires/functions are not storage. These are logical
source counts, not measured FF/LUT/BRAM/DSP usage. Risk is LOW default /MEDIUM
maximum because physical RAM packing and the multiplier path remain unmeasured.

There are15 controller states. Every good cell costs start1 + four clocked
read/consume pairs8 + classify1 + advance1. An alternating cell adds4 arithmetic
edges. Each emitted segment adds MAKE1 and an unstalled retirement1. Let K be
the segment total and B the alternating-cell count. With an always-ready sink,
the edge distance from final accepted input to accepted summary is exactly

```text
3 + 11*C + 2*K + 4*B <= 19*C+3.
```

It is at most **4,278 default /75,414 maximum** edges. A zero-cell or rejected
frame takes exactly3. There are exactly4C clocked reads and2B multiplies for a
good frame; errors do none. Every sink hold adds one edge. Capture time and its
source gaps are outside this tail. No video-rate or physical timing claim follows.

## Sealed finite evidence and offline integration

Before writing any RTL/TB, `prepare_matrix.py` generated and sealed MATRIX.json
and all66 actual fixtures. It uses only the Python standard library. Its oracle
evaluates bilinear critical-point coordinates and the four interpolation terms
with Fraction arithmetic, then isolates corners opposite to the saddle sign.
It does not use the RTL Q-pairing table or controller. All shared-edge IDs and
fractions, complete boundary/interior node degrees, endpoint interpolation and
local noncrossing chords are independently certified before fixtures are written.

The9 profiles (W,H,G,T) are1/1/1/1,1/7/8/3,7/1/3/8,2/2/1/1,
2/2/2/8,3/3/3/8,5/4/5/5,16/16/8/8 and64/64/12/32. Every profile has16 fixed
directed/error frames. The2x2 G1/G2 profiles add all32/1,024 pixel/half-level
assignments;3x3 adds all512 binary0/7 masks at levels0.5,3.5,6.5 (1,536 frames).
Total main frames are2,736, with34,601 records. Directed cases include empty,
constant, maximum level, horizontal/vertical structure, nested levels, both
checkerboards, seeded grayscale, extreme edge fractions, isolated SOF/EOL/
upstream errors and their combination. Both Q signs and both Q0 orientations,
all16 sign patterns and real magnitude-dependent topology receive coverage.

There are35 specific reset target IDs. MATRIX.json lists every target and each
profile's explicit exclusions: no numerical states without2x2 cells; no partial
prefix for N1; no nonzero alternating saddle for G1; no nonfinal cell-row wrap
for HEIGHT<3. The226 included probes cover all15 reachable states, every read/
consume slot,0/2/4 crossing classes, both multiply phases/save, Q+/Q-/Q0, first
and second ambiguous segments, held single/ambiguous segments, row/final-cell
advance, successful nonempty/empty summary, combined-error drain and summary.
At a falling-edge observation the TB immediately asserts reset with **no active
edge intervening**. Each probe then accepts and compares one complete fresh
same-geometry checkerboard raster, every segment and its summary, using a
distinct captured tag. Full fresh frames total295,058 records and exercise the
complete reachable arithmetic at the declared geometry; line/point cases
correctly have no2D numerical work.

The TB compares every output bit, validates complete unsigned fixture values
before narrowing, checks actual queued next-pixel acceptance one edge after
summary, snapshots, complete source/output stability, fixed source gaps and
three full holds per output, accepted RAM writes, complete ownership before
reads, clocked read-q hold/read behavior, every deviation/product/determinant,
exact read/multiply work, exact tail after subtracting sink holds, and all reset
control/public fields. The complete owner frames and expected results are also
frozen; any retired prefix before cancellation is checked.

All66 jobs and143 compiler/simulator/version/reject children are fixed before
RTL. At maximum geometry only the first two cheaper constant-empty main frames
share a child; every other main frame and every reset ID has its own child.
Every child has a20-second hard deadline. TIMEOUT is terminal: no retry, smaller
stimulus, changed split or longer deadline. An ordinary FAIL preserves complete
exact sources, plan, raw receipt and NOT_RUN tail before any root-authorized
repair. Existing receipts block automatic reruns. No inherited, synthesis, PnR,
STA, board or expanded checks are invoked. Read-only reviewers do not run the
runner, oracle, compiler, simulator or package checker.

`TEST_PLAN.json` seals all final source hashes and exact commands before the
first HDL child. Owner commands are `python -B run_tests.py --freeze-source`,
then `--run`; `--audit` verifies the completed receipt offline without HDL or
oracle execution. `prepare_matrix.py` refuses to regenerate an existing matrix.
The raw receipt is the authority for LINT_PASS /UNIT_SIM_PASS status.

Production `files.f` closes over one local RTL. `example/files.f` adds the
complete default `iso_graph16` direct instance. No Python, fixtures, network,
NumPy, scikit-image or sibling RTL is needed for production offline use. An
ordinary-RV grayscale source can forward pixel/markers/tag and reduce its error
vector into s_error while supplying the chosen first-pixel level. A CE-qualified
neighbor requires an explicit adapter. Endpoint segments cannot be wired into
the old ordered binary-contour interface by port-name similarity. Root LICENSE
and NOTICE apply to this independent implementation; reading/dedup evidence is
in SOURCES.md.

# Exact simple-polygon triangulation

`polygon_triangulation` converts an ordered, possibly concave integer polygon
to a complete triangle mesh. It retains every input boundary vertex, including
forward collinear vertices. For a successful N-vertex polygon it emits exactly
N-2 nondegenerate triangles, using original retained vertex IDs and exact input
coordinates. Triangles have positive Cartesian cross product (x right, y up);
on a y-down display this order appears clockwise. Each step selects the
smallest original ID which is a legal ear in the remaining ring. A negative
input winding swaps that triangle's second/third IDs. The final three vertices
use remaining original-ID order with the same winding normalization.

This adds concave-polygon decomposition, distinct from hull, contour tracing,
polyline simplification, parity raster filling and coordinate resampling.
There is one implicit closing edge, one ring and no hole list. Coordinates are
two's-complement integers with their complete signed range, with no rounding,
tolerance, fractional scale or quantization.

## Domain, protocol and errors

A valid ring has at least three distinct coordinates, nonzero signed area,
no nonadjacent edge intersection or touch, and no adjacent collinear backtrack
or overlap. Forward collinear boundary vertices are legal. A repeated explicit
closing vertex is a duplicate and rejected. Self-crossing, self-touching and
zero-area paths are rejected; no repair, hull substitution or partial mesh is
published. Global validation and complete mesh construction precede output.

Parameters are COORD_W=8 (2..12), MAX_VERTICES=16 (3..32), TAG_W=8 (1..32).
Invalid static parameters fail elaboration with the named marker
`polygon_triangulation_invalid_parameters__see_README`.

All ports use one rising-edge clock, synchronous active-high rst and ordinary
ready/valid. There is no CE, CDC, runtime configuration or external memory.
Hold every source field and valid until acceptance or reset. `s_keep` appends
the coordinate; masked tokens still carry `s_error`, tag and `s_last`. The
first accepted token's tag is retained, even if masked. Later tags are ignored.
`s_last` ends capture even on a masked token. Missing last requires finishing
the source transaction or reset; there is no implicit restart or timeout.

The retained ordinal is the original vertex ID. At capacity further kept
tokens latch overflow and are drained through last. Input accepts at II=1
with gaps and stays blocked from last through final output retirement. The
next polygon can be accepted on the following edge. All output fields and
valid remain stable under backpressure. rst immediately gates ready/valid and
first/last low; its active edge cancels the transaction. Current ownership and
complete writes before reads protect unreset RAM and private read registers.

Output fields: three IDs, their three signed x/y pairs, original `m_vertices`,
total triangle `m_count`, zero-based triangle `m_index`, first/last, tag, error.
Payload is meaningful with valid only. Errors are independent sticky bits:

| Bit | Meaning |
|---|---|
| 0 | Capacity overflow |
| 1 | Upstream s_error, including masked/excess tokens |
| 2 | Invalid geometry or fewer than three retained vertices |
| 3 | Defensive internal failure (no ear or inconsistent final triangle) |

External bits 0/1 skip geometry after draining last, so unevaluated geometry is
not labelled bad. Geometry failure stops processing; bit3 only guards later
construction invariants. Every error emits one held token with zero IDs,
coordinates, vertex/triangle counts and index, first=last=1, the complete error
bits and first tag. No truncated prefix mesh escapes. Reset aborts held output;
the caller must discard any earlier triangles from the canceled transaction.

## Architecture and bounds

Two single-port clocked-read coordinate banks, one ring-ID bank and one packed
triangle-ID bank have disjoint scheduled accesses. Compacting the ring uses
one read edge and one write edge per moved ID. Vertex loading takes three
edges per slot: ring-read (idle for direct IDs), coordinate-read, buffer latch.
One shared source-level signed (C+1)x(C+1) multiply expression is used twice
per cross product. Differences, both products and the cross subtraction are
registered in four separate states. Maximum operands are 13x13; physical DSP
or LUT mapping is unmeasured. No data division, ROM, external code or sibling
module is needed. There is no combinational array reset/shift structure.

Differences DW=C+1 cover opposite signed extremes; PW=2DW products and
XW=PW+1 cross products are exact. AW=XW+IW stores the complete area fan sum,
IW=clog2(MAX_VERTICES), CW=clog2(MAX_VERTICES+1). The 44-state FSM uses 6 bits.
All clocked scalar, read and public buffer declarations total exactly
`22*C+5*CW+9*IW+TAG_W+57` bits: 302 default, 428 maximum. Four logical RAM banks
total `2*C*N+N*IW+3*(N-2)*IW` bits: 488 default, 1378 maximum. These are source
declaration counts, not mapped FF, RAM, DSP or device utilization results.

For a good N-vertex input, define P=N(N-1)/2 and Q=N(N-3)/2. Tail acceptance to
first valid is bounded by
`9P+33Q+32N-1+sum(20K*K-36K-2, K=4..N)` clocks: 122 at N3, 29957 default,
230469 maximum. Duplicate pairs cost 8 edges, adjacent triples 16, nonadjacent
edge pairs 34 (adjacent pairs 1), fan terms 16, each ear candidate <=20K-39,
compaction <=3K-2, final triangle 17 and first replay 11. Reject paths stop
earlier; external-error/short transactions take two clocks. Unstalled triangle
valids are 12 clocks apart; each sink stall adds a clock. Input/output stalls
are unbounded. This is a serial geometry preparation service, not a live-video
throughput claim. Resource risk is qualitatively MEDIUM, with no physical,
timing, power, synthesis, PnR, STA or board evidence (`HW_UNVERIFIED`).

## Frozen finite qualification

MATRIX.json was saved before RTL. `python run_tests.py --freeze` materializes
the predetermined fixtures and source-bound TEST_PLAN before any HDL child.
`--run` executes exactly that matrix with a 20-second hard timeout per child.
Timeout is terminal: no retry, stimulus shrinking, later split or longer limit.
Ordinary failure preserves every exact source, plan, receipt and NOT_RUN suffix
in a new failure_archive directory before any repair. A receipt is never
overwritten, and a successful receipt is immutable.

Five configurations cover minimum/default/maximum parameters. Small cases are
all 729 ordered grid triples and all 3024 distinct ordered grid quads, the
latter split into four fixed 756-case children before any HDL. Directed cases
cover both windings, concavity, forward collinear vertices, full capacity,
signed extremes, invalid crossings/touches/backtracks/duplicates, metadata,
masks, overflow and upstream combinations. N32 main stress and all reset groups
are split in advance. Each immediate falling-edge reset is followed by a
complete full-capacity convex fresh polygon, every triangle held and retired.
Unreachable N3 edge/ear reset IDs are explicitly excluded rather than aliased.

The independent reference uses exact Fraction segment/diagonal visibility,
midpoint polygon winding and interval triangulation feasibility. Small meshes
also enumerate all triangulations. Mesh certificates verify orientation,
area conservation, original boundary edges once, internal edges twice in
opposite directions, and disjoint interiors. The TB compares every public bit,
checks actual next-token acceptance and whole-word stability, and shadows all
four banks including clocked read values/current ownership. Verification.json
records actual command results and hashes; only its actual status is evidence.
No expanded or inherited regression is included. `files.f` and
`example/files.f` provide complete standalone and polygon_mesh16 closure.
Fixed upstream and full-license preflight are in SOURCES.md.

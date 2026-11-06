# Architecture, numerics and service budget

The required output is exact area for a single runtime fractional rectangle.
A dense center-sample mask discards area, a supersampling grid needlessly
approximates this separable geometry, and a general polygon scan converter
adds edge machinery. Exact intersection of two one-dimensional intervals
is sufficient. We clip once, scan the positive-area bounding box, multiply
one9-bit horizontal extent by one9-bit vertical extent, and hold each result
until accepted. No framebuffer, line RAM, texture storage or general divider
is needed. The chosen core initiation interval is2, trading throughput for a
small registered area datapath. The actual blend serializes four channels
through one17x8 multiply; production Porter-Duff arithmetic is reused intact.

| Node | Representation and full supported range |
| --- | --- |
| Input endpoints | signed24 /256, -8388608..8388607 subunits |
| Clipped edge | unsigned17, 0..65536 subunits |
| Pixel index | unsigned8, 0..255 |
| Positive overlap | unsigned9, 1..256 subunits |
| Full overlap product | unsigned18, maximum65536; bit17 is zero |
| Published area | unsigned17, 1..65536 /65536 pixel |
| Accepted count | unsigned17, 0..65536 |
| Accepted area sum | unsigned33, 0..4294967296 |
| Paint product | unsigned25, 0..16711680; bit24 is zero |
| RNE paint quotient | unsigned9 including increment, actual0..255 |

Unsigned clipped edges avoid negative floor-division hazards. Sparse start
indices use edge>>8, inclusive end indices use (exclusive edge-1)>>8 only
after nonempty validation. The full256 boundary has bit16 set and never
becomes an8-bit start index for a valid interval. Pixel upper edges use17 bits
so pixel255 can end at65536. Exact sum maximum requires33 bits;32 would wrap
a full maximum viewport. Count includes65536, hence17 rather than16 bits.

Core IDLE/CALC/OUT/DONE states distinguish input ownership, registered area,
fragment stall and completion stall. Only fragment acceptance advances scan,
count or sum. The wrapper F_IDLE/F_SCALE/F_PUSH/F_WAIT keeps area metadata and
destination immutable while scaling and production output are pending.
Its independent command owner extends beyond core geometry completion and
through wrapper completion retirement. This prevents new paint/mode capture
while any composed fragment or completion depends on them.

Expected hardware is a small control/register/compare datapath with one9x9
multiply and the actual wrapper's one17x8 multiply plus existing production
blend operators. A synthesis tool may infer DSPs or LUT multiplication; no
count is measured. Main expected paths are clip comparisons at command input,
min/max subtraction into the9x9 area multiply, and the scaler's multiply/RNE
increment. No target clock, FPGA family, LUT/FF/DSP/Fmax/power or board-fit
result is asserted. Geometric exactness is limited to axis-aligned rectangles
whose edges are exactly representable at1/256 pixel.

Finite TB budget: regular core output acceptances need at most4 clocks per
fragment with the periodic ready pattern (at most2 consecutive low clocks);
the test adds at most3 clocks to load each next expected record and schedule
its sink. Conservatively7*65825 +24*10 +1000 reset/queue clocks <463000.
Wrapper fixtures have at most311 fragments; even32 clocks per fragment plus
44*10 +2000 reset/queue clocks <13000. The500000-cycle watchdog covers these
finite fixtures. These are test-scheduling bounds, not unconditional service
guarantees under arbitrary external stalls. Every process independently has
the fixed20s deadline; no watchdog enlargement or retry is automatic.

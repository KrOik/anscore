# Exact subpixel rectangle area coverage

`subpixel_rect_coverage` converts a runtime half-open axis-aligned rectangle
with signed Q8 edges into a sparse row-major stream of exact pixel-cell areas.
It adds geometric antialias coverage to the existing binary rasterizers and
texel reconstruction filters. It emits every positive area, including 1/65536
pixel. It does not sample a texture or store a framebuffer.

Status: **AUTHORED / EXECUTION_PENDING / HW_UNVERIFIED**. The finite plan is
not executable until the exact source and plan receive separate root/peer
review and a unique gate. No physical implementation claim is made.

## Geometry and numeric contract

Parameters `WIDTH,HEIGHT` are 1..256 (default64), `TAG_W` is 1..32 (default8).
All command endpoints are signed24 integers in units of 1/256 pixel, covering
[-32768,32767.99609375]. Geometry is `[x0,x1) x [y0,y1)`; the viewport is
`[0,WIDTH) x [0,HEIGHT)`. Reversed endpoints produce status1 BAD_RECT before
any zero-extent test. Otherwise, a zero extent or empty viewport intersection
produces status2 EMPTY. Both cases emit no pixels. Status0 OK emits only
positive intersections in increasing y, then increasing x.

For each pixel, exact overlap lengths dx,dy in subpixel units produce
`m_area=dx*dy`. Area is unsigned17 in units of 1/65536 pixel: minimum1,
full pixel65536. No byte-alpha approximation or center-sample predicate is
used. Coordinates are unsigned16, zero extended from the supported viewport.
`m_last` marks the final positive-area pixel; all fragments echo captured tag.
Completion reports accepted fragment count (unsigned17) and area sum
(unsigned33), plus status and captured tag. The maximum count65536 and
area sum4294967296 (2^32) are representable. The sum equals the clipped
rectangle width times height in subpixel units.

## Handshake and cancellation

All interfaces are ordinary rising-edge ready/valid with synchronous high
reset and no CE/CDC. Commands capture all fields at `c_valid && c_ready`.
The owner accepts one command through completion retirement. There is no
same-edge command fallthrough when completion retires. Fragment and completion
payloads remain stable throughout any stall. External valid, ready and busy
signals are masked low while rst is asserted; the rising reset edge cancels
all unretired work. Fragments already accepted before reset remain accepted.

A normal command accepted at edge0 has its first fragment valid after edge1;
an always-ready sink first accepts it at edge2. Further fragment acceptances
are two edges apart. Completion becomes valid immediately after the last
fragment acceptance edge, and can first retire on the following edge. An
invalid/empty command has completion valid immediately after its command
acceptance edge. An unstalled command of P positive pixels completes transfer
at edge2P+1. Unbounded sink stalls remove a wall-clock completion guarantee.

## Actual premultiplied RGBA composition

`example/rgba_aa_rect_blend.sv` instantiates the coverage core and unchanged
production `rgba_porter_duff`. A coverage fragment and one ordered destination
pixel rendezvous atomically: each is accepted only with the other. Coordinates
come from the coverage stream; the caller supplies the corresponding destination.
One fragment is owned until the real composed output retires. The wrapper
does not fetch or address memory.

The command captures premultiplied `{R,G,B,A}` paint and Porter-Duff mode.
All four paint bytes are multiplied by exact17-bit area and divided by65536
with round-to-nearest, ties-to-even, using one multiply over four cycles.
Full coverage is identity, zero covered geometry emits no fragment, and tiny
positive coverage may emit a transparent source. Valid premultiplication is
preserved by monotone channel rounding. The unchanged blend then applies
its denominator255 rounding and saturation. All13 production modes are used.
The result carries area and last alongside production color/error/mode/x/y/tag.

Malformed original paint is captured before scaling and presented to the real
blend as a guaranteed malformed source sentinel, preserving the production
error priority: invalid mode1, bad source2, bad destination3. Error outputs
are zero color. `r_error_count` counts retired composed fragments with nonzero
error. Empty/BAD_RECT geometry consumes no destination, invokes no blend and
reports zero errors regardless of unused paint/mode. Completion is hidden
until the last composed output retires; command ownership ends only when the
wrapper completion retires. Reset cancels coverage, scaler and real blend.

Without stalls, a destination/coverage pair captured at edgeT is scaled at
T+1..T+4, enters production blend at T+5, becomes output valid after T+7,
and first retires at T+8. The next pair can retire into the wrapper at T+9:
pair initiation interval9. The first pair of a new normal command is accepted
at edge2; P pairs complete wrapper completion transfer by edge9P+3.
This area-oriented serial architecture makes no dense video-rate claim.

## Integration and finite verification

Resolve `files.f` and `example/files.f` from this package directory. The real
dependency is already committed in BASE d32ea87e268c5957b7203560a5b46864e282a6e1;
its exact blob and source provenance are recorded in `SOURCES.md`.

Five archived standalone cell-histogram preparations precede two syntax
children and five compile/simulation pairs: core1x1/TAG1, core7x5/TAG8,
core256x256/TAG32, actual blend7x5/TAG8, actual sparse blend256x256/TAG32.
Core fixtures have24 commands and13/75/65825 exact fragments; blend fixtures
have44 commands and93/311 exact fragments. The maximum core includes one
full256x256 traversal checking count65536 and area2^32. The actual maximum
wrapper fixture spans at most256 pixels per command, without a dense-frame
throughput assertion. Geometry covers signed extrema, every clip boundary,
integer/fractional boundaries, area1/full, empty and reversed commands.
Blend cases cover RNE ties, all13 modes and preserved error priorities.

The TB poisons inactive live commands, drives a real future command while
busy, holds fragments/completion, stalls destinations/composed outputs, and
checks fixed record counts plus strict EOF. Core profiles cancel calculation,
held fragment, partial traversal and held completion. At1x1 the partial case
degenerates to a completed single pixel; the other profiles exercise a real
partial traversal. Actual wrappers additionally cancel SCALE, PUSH and live
production blend stages. Every cancellation requires a fresh recovery.
One finite simulation watchdog is500000 cycles. Execution is exactly17
children, with20s child /5s tree termination / one shared2s exit-drain limit.
Failure stops later launches and retains original evidence; no automatic retry.
See `PRECHECK_PLAN.json` and `SOURCE_SEAL.json` before the reviewed command:

```text
python -B run_checks.py --execute-approved-plan
```

No synthesis, PnR, STA, board or PPA job is included.

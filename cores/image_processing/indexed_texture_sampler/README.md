# Resident indexed texture sampling

Original Apache-2.0 two-level texture service: a runtime-loaded 8-bit index
image and 256-entry straight RGBA32 palette turn sparse texel-coordinate
requests into RGB/alpha fragments. The resident image is reused across requests
and primitives. This is distinct from fixed CGA sprite blending, packed-pixel
geometric resampling and codec-private palette expansion. Existing RTL is not
modified. B37 baseline: `46630205095a13ab95e1b5bebea0094c2a390390`.

## Numerical and visibility contract

Compile-time TEX_WIDTH/TEX_HEIGHT are 1..256, default64x64; TAG_W is1..32,
default8. A request contains unsigned u8/v8 **integer texel coordinates**, plus
opaque destination x16/y16 and tag. No normalized coordinates, interpolation,
wrapping, clipping of destination coordinates or perspective division occurs.
For in-range u/v, the index is `texture[v*TEX_WIDTH+u]`, and RGBA is
`palette[index]`, with A in31:24 and RGB in23:0. Every request yields exactly
one result, including transparent/out-of-range requests. No result is silently
dropped by the service.

`m_visible=1` iff u/v are in range and palette alpha is nonzero. `m_reason`
bit0 marks UV out of range; bit1 marks zero palette alpha for an in-range texel.
An out-of-range request returns RGB=0, alpha=0, reason=1, and does not read an
uninitialized address. An in-range transparent texel returns its actual stored
RGB, alpha=0, reason=2. Other results have reason0. Alpha is straight unsigned8,
0..255; sampling performs no alpha blending or gamma correction.

## Loading, publication and management

One clock, synchronous active-high reset, **ordinary valid/ready**, no CE or
CDC. Reset masks all public readies/valids and cancels pending responses and
lookups; RAM payloads are not reset. Sources hold every field while blocked.
All results and management responses remain stable under arbitrary backpressure.

Management c_op0 BEGIN discards resident ownership and enters a fresh load
epoch, resetting only the two counters. Independent index and palette ports
accept exactly TEX_WIDTH*TEX_HEIGHT indices and256 RGBA entries in sequential
address order. Both may transfer simultaneously. Full ports backpressure extra
entries. c_op1 PUBLISH succeeds only after both complete streams; a premature
PUBLISH returns INCOMPLETE and leaves the load epoch/counters intact. Following
successful publication the RAMs are read-only until a new BEGIN. Palette or
texture replacement requires a complete fresh load epoch.

Management returns one held response: status0 success,1 incomplete load,
2 PUBLISH outside loading,3 unsupported operation; tag and accepted-count
snapshots accompany it. BEGIN is legal in any mode. A pending management offer
stops new lookup/load admission. Management can transfer only after **all**
index, palette and output pipeline stages drain, and after any earlier held
management response retires. No same-edge response/command fallthrough occurs.
No lookup is accepted while loading, uninitialized or a management response is
pending. There is no timeout or implicit recovery from a truncated source.

## Architecture and cycle budget

Index RAM contains `8*TEX_WIDTH*TEX_HEIGHT` bits; palette RAM contains8192bits.
Default logical storage is40,960bits; maximum is532,480bits. Each RAM has one
selected synchronous access per edge; mutually exclusive load/resident phases
prevent write/read collisions. Dependent reads are index RAM, then palette
RAM, then registered output. A single global pipeline advance freezes both RAM
read enables, metadata and valid bits on held output. There are no data
multipliers/dividers; address stride is an elaboration constant.

With output always ready, output valid appears two rising edges after request
acceptance and its earliest output handshake is three edges after request
acceptance. The three finite core profiles verified the three-edge handshake
latency and II=1. A management command cannot be accepted on the same edge as
the final result retires; it becomes eligible on the following edge if no held
management response remains. Source/sink stalls have no unconditional transaction deadline. Default
storage risk MEDIUM; maximum storage HIGH, before physical block packing.
Logic/routing risk MEDIUM/UNKNOWN. No synthesized area, device fit, clock rate
or continuous display throughput is claimed. Synthesis/PnR/STA/board are NOT_RUN;
hardware remains HW_UNVERIFIED.

## Actual rendering composition

`example/indexed_triangle_frame.sv` connects unchanged B33
`triangle_rgb_raster`, this service and unchanged B35
`fragment_rgb_depth_store`. All interfaces use the same ordinary handshake and
reset; no CE-qualified peer is connected without an adapter. Triangle vertex
attributes `{U8,V8,0}` use the rasterizer's existing exact affine barycentric
half-up interpolation. The resulting U/V bytes are integer point-sample texel
coordinates; quantization happens before texture bounds checking. This is an
affine 2D texture mapper, not perspective-correct texturing, antialiasing,
mipmapping or subtexel filtering.

The example snapshots per-primitive depth/depth function/depth-write/color-mask
at command acceptance, retaining them through every sample and held primitive
completion. A transparent result retires internally with **no RGB/Z store
transfer**, so even enabled depth-write cannot update Z for it. Visible
fragments use the palette's straight alpha and the store's exact /255 blend.
A lookup in-flight counter includes every sample until its result retires.
Primitive DONE and frame END cannot pass pending sample results; END also
honors the store's own write-commit readiness. Texture management is blocked
for the entire primitive, including gaps where the sampling pipeline is empty.

All source lists are package-root-relative. No texture/palette init file,
vendor primitive or online dependency is required: callers load actual data.
The finite runner, independent oracle, TB and exact precheck plan must be
reviewed before numerical preparation or HDL execution. Freeze/archive exact
executable inputs first, then generate/archive every vector before the first
HDL child. Each child has a20-second deadline, bounded tree cleanup and
failure-stop behavior; no automatic retry. Any existing report directory,
including an empty started directory, blocks a new runner attempt. A durable
INCOMPLETE receipt precedes oracle import and is checkpointed around numerical
preparation and after every child. Raw evidence remains immutable.

## Finite qualification

The authorized first attempt passed all11 children and4 simulations in
`reports/20261106T043049833910Z/results.json`: 696 sampler outputs across
1x1/TAG1, 9x5/TAG8 and256x256/TAG32, plus384 RGB/Z records from two complete
16x12 frames. The maximum texture profile loaded all65,536 indices and256
palette entries once, then checked only72 sparse requests. The example accepted
19 triangle commands:18 completed and1 canceled by a live reset. Five core
live-reset phases and the example's live reset were followed by fresh complete
loads. Metadata, visibility, alpha, held outputs, management drain, primitive
ownership and full RGB/Z output agreed with the independent oracle.

All11 current/archive inputs,18 vectors,22 raw streams, the plan and both tool
binaries were hash-verified after execution. Icarus emitted inherited/no-explicit
timescale and array-sensitivity notices from the unchanged dependencies; all
simulation stderr streams are empty. `QUALIFICATION.json` and
`B37_DELIVERY.json` record the bounded evidence and retained VVP hashes.
LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED; this does not
establish synthesized RAM inference, physical memory fit or device frequency.

## Reference review

Project F `projf/projf-explore` commit
`dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708`: actual
`graphics/hardware-sprites/sprite.sv`, `lib/display/clut_simple.sv` and `LICENSE`
were read before implementation. The actual license is MIT. They inform the
index/palette boundary; no upstream source is imported, translated or executed.
Unlike its scan-timed asynchronous sprite ROM and separate CLUT, this package
defines a resident-load epoch, dependent synchronous reads and backpressured
sparse transactions. Original package code is Apache-2.0.

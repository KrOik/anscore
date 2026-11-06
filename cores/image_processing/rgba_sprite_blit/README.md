# Resident indexed sprite rectangle blits

Original Apache-2.0 `rgba_sprite_blit` converts a source rectangle, signed
destination origin and optional X/Y flips into texture requests and sparse
straight-RGBA fragments. The actual `indexed_sprite_frame` example composes the
unchanged B37 resident indexed sampler and B35 RGB/depth framebuffer. Baseline:
`816d461b12fd402f6a146ca74c7491c7afbd3091`.

B35 already provides persistent coordinate-addressed RGB storage, ordered
overlap updates, exact alpha blending, bounds rejection and held full readback.
B37 already provides resident index/palette lookup. Those implementations are
reused unchanged. The new capability is a rectangle blit command service with
source validation, signed destination intersection, flips and ownership through
committed writes. No new alpha arithmetic or framebuffer RAM is duplicated.

## Rectangle and numeric contract

All interfaces use ordinary same-clock valid/ready, synchronous active-high
reset, no CE or CDC. Reset masks public ready/valid and cancels the current
command, outstanding lookups and counters. Peers must reset together. An
already consumed output prefix cannot be undone.

Parameters WIDTH/HEIGHT are1..128, defaults64x64; TEX_WIDTH/TEX_HEIGHT are1..256,
defaults16x16; TAG_W is1..32, default8. The controller contains no pixel RAM.

Command `c_u/c_v[7:0]` is the unsigned top-left source texel; width/height are
unsigned9-bit extents. `c_x/c_y` are signed16-bit destination origins, referring
to the top-left of the unflipped destination rectangle. Flip flags reflect
source texels within that original source rectangle; destination traversal is
always increasing X within increasing Y. For destination `(x,y)`, offsets are
`col=x-c_x`, `row=y-c_y`; source coordinates are:

```
u = c_u + (flip_x ? width-1-col : col)
v = c_v + (flip_y ? height-1-row : row)
```

Zero width OR zero height is a successful no-op, with no source validation or
memory access even when unused origins/extents are outside the normal domain.
Otherwise both extents must be1..256 and the entire source rectangle must be
inside the compile-time texture. An invalid source rectangle returns status1
and never partially draws. Destination clipping does not excuse a source error.
After source validation, an empty destination intersection returns status2;
all other commands return status0. The controller computes the intersection
before traversal using signed18-bit endpoints; even a256x256 rectangle entirely
offscreen requires no per-texel scan. Only intersection pixels issue requests.
Wide signed arithmetic precedes coordinate narrowing, including origins
−32768/32767 and positions that cross zero or the last viewport pixel.

Every accepted command snapshots all fields. `q_*` requests carry integer UV,
in-range destination x/y16 and the command tag; all fields remain stable while
blocked. The source must return exactly one ordered `s_*` response per request,
with its original destination coordinates. Response latency is at least one
edge; a same-cycle combinational response is unsupported. At most three
requests are outstanding, with a retiring response allowing same-edge slot
reuse. No response may arrive before its request or after reset cancellation.

`s_rgb` is straight/unpremultiplied RGB8 and alpha is exactly0..255. Invisible
or alpha-zero responses retire without an `m_*` fragment transfer. Visible
responses forward RGB/alpha and coordinates unchanged. Fragment payload and
the upstream response remain held under sink backpressure. The destination
consumer must assert `writes_idle` only when every accepted fragment has
committed; accepting a fragment alone is not completion. This is separate
from generic `m_ready` capacity.

Held `d_valid` returns the command tag, status and17-bit requested/written/skipped
counts. These count accepted lookups, visible fragment transfers and invisible
responses. Maximum counts are65,536; no wrap or saturation is needed in the
legal domain. DONE waits for all responses and `writes_idle`; its written count
therefore refers to committed fragments. No subsequent command is admitted
until DONE retires. Missing source responses or unbounded backpressure can
stall forever; no implicit timeout or recovery is invented.

## Actual framebuffer service

`example/indexed_sprite_frame.sv` exposes the B37 load/publication management,
B35 BEGIN/END and the blit command interfaces. A frame begins with a complete
clear before any blit is admitted. It requires a resident texture, no held or
pending texture management, an empty sampling pipeline and ready framebuffer.
It blocks texture commands for the entire blit, including held DONE, and gates
the sampler's management offer so it cannot stop an owned blit's lookup drain.
END waits for that owner and the sampling pipeline, then honors the framebuffer's
own write-commit readiness. A pending END takes priority over an unaccepted
new blit. BEGIN parameters and frame tag are latched by the unchanged store.

The store receives fixed ALWAYS depth mode, depth_write=0 and RGB mask111. Its
unused Z plane clears to65535 and remains unchanged. Transparent samples never
reach it. For each channel, existing B35 arithmetic remains exactly:

```
floor((source*alpha + destination*(255-alpha) + 127)/255)
```

Alpha0 preserves the destination and255 replaces it. This is straight-alpha
source-over onto an RGB destination with implicit alpha255; destination alpha
is not stored or exported. There is no premultiplied input, gamma conversion,
scaling, filtering, arbitrary affine transform or source texture writeback.
Overlap is ordered by accepted blit commands; the prior command's last write
commits before the next command can begin. RGB raster output, markers, frame
tag and DONE remain held under backpressure. Frame drawing and export do not
overlap, and a new frame requires another clear.

## Architecture budget and finite scope

The new controller uses about200 control/coordinate/count bits, bounded add/sub,
compare and selection logic; no RAM, variable multiplier, divider or vendor
primitive. The actual chain conservatively contains174,080 logical RAM bits at
defaults and1,187,840 at maximum, counting the reused store's40-bit words and
the sampler's index/palette banks before any pruning of unused Z bits. Default
storage risk MEDIUM, maximum HIGH; logic/control risk LOW/MEDIUM. Existing
blend arithmetic is three signed9x9 products; the controller adds none.
Physical packing, operator mapping, device fit and Fmax are unmeasured.

Visible fragments are bounded by the reused store's II4 service; transparent
queries can stream at II1 when both endpoints allow it. Clear/export and
command setup/drain add latency. These are source-derived schedules, not a
measured hardware throughput or real-time scanout guarantee.

PRECHECK_PLAN fixed11 children: three syntax checks, three core compile/sim
pairs and one actual example compile/sim pair. Profiles include1x1/TAG1,
9x6/TAG8 and128x128/TAG32 with256x256 source bounds; the last uses selected
small rectangles plus constant-time empty256x256 clips, not a large traversal.
Core checks use two finite scenes, one SETUP reset and one held-DONE reset.
The actual8x8 indexed sprite chain checks two16x12 RGB frames,35 accepted blits
(34 completions and one reset-canceled pending write), source/destination
boundaries, flips, overlaps, all six selected alpha extremes, management/END
ownership and held readback. No maximum framebuffer scene or old regression
was run. Root and worker B reviewed source/model/TB/plan before numerical
preparation or HDL.

The runner archives all11 exact inputs before oracle import, prepares vectors
once, hashes them before the first HDL child and persists INCOMPLETE checkpoints.
Any existing report directory, including empty, blocks another attempt. Every
child has a20-second deadline and bounded cleanup; first failure stops later
launches, with no retry. Synthesis/PnR/STA/board remain NOT_RUN.

## B38 finite evidence

The authorized first run passed11/11 children and4/4 simulations with one
numerical preparation and no failure, timeout, cleanup or retry. Receipt:
`reports/20261106T051200293320Z/results.json`, SHA256
`2c51e7a6ae3f102bfc73e75f89db017e07059eed6998faf7b412f83769252268`.
All11 executable inputs match their archived copies, all24 frozen vector files
and22 raw streams match their recorded hashes, and both tool binaries match.
The four successful simulations reached `$finish`. The maximum child duration
was0.484 seconds. PRECHECK_PLAN remains the frozen pre-run artifact; the receipt,
QUALIFICATION.json and B38_DELIVERY.json describe the completed execution.

The three core profiles checked430 UV/metadata requests,324 visible fragments
and102 DONE records. The actual chain checked two complete16x12 RGB frames
(384 pixels) and34 DONE records. Across all profiles,140 commands were accepted,
136 DONE records checked and four commands reset before a DONE check (three
SETUP, one actual pending framebuffer write). Three additional checked DONE
responses are reset while held, before their retirement. Eleven resets comprise four initial and
seven live resets. Core sink holds total700 cycles, with128 held frame-output
cycles. Maximum observed source flight was three in both larger core profiles.
The1x1 case intentionally sampled only transparent responses; the other core
profiles and actual example exercise alpha0/1/127/128/254/255. Each completed
actual frame observed81 passed fragments, zero coordinate errors and25
transparent samples.

Core compilations report no-explicit-time-unit/precision notices; the actual
composition reports inherited-timescale notices for the controller, example
and unchanged framebuffer. All simulation stderr streams are empty. No
functional assertion failed. Maturity is LINT_PASS / UNIT_SIM_PASS /
INTEGRATION_CANDIDATE / HW_UNVERIFIED. This finite result does not establish
maximum-size traversal/rendering, physical RAM packing, device fit, Fmax or
hardware throughput.

## Primary reference

Actual Project F `graphics/hardware-sprites/sprite.sv` and full MIT `LICENSE`
were read at fixed commit `dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708` before
implementation. They informed signed sprite position and scan lifecycle review.
No upstream source was imported, translated or executed. Unlike that scan-timed
asynchronous ROM sprite, this service has runtime rectangles, pre-intersection,
ordinary backpressure and explicit completion after framebuffer writes.

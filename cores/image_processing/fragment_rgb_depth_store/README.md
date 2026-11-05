# RGB/depth fragment framebuffer

`fragment_rgb_depth_store` turns ordered coordinate-addressed RGB fragments
into a persistent RGB24/Z16 framebuffer. It performs depth testing, optional
depth writes, RGB channel masks and exact straight-alpha blending against the
stored destination. BEGIN clears a frame; END drains fragment work and exports
the complete RGB/depth raster with markers and a held completion. The actual
`triangle_depth64` example connects the unchanged B33 triangle rasterizer.

Status: **LINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED**.
One finite run passed all 10 children and compared 54,116 output pixels,
including three complete maximum-size frames and the actual triangle chain.
No synthesis, PnR, STA, board, power or physical video-rate check was run.

## Frame and fragment contract

All ports share rising-edge `clk`. `rst` is synchronous active high and
overrides every phase; transfers require `!rst && valid && ready`. There is
no CE, CDC or implicit timeout. Sources hold all fields while valid and blocked.
Reset cancels clear, fragment RMW, raster or held DONE and returns to IDLE.
RAM payload is not reset. A fresh complete BEGIN clear always precedes any
accepted fragment or export, so old RAM contents cannot become a valid frame.
Reset cannot undo a raster prefix already consumed by the downstream system.

Parameters: `WIDTH` and `HEIGHT` independently 1..128 (defaults 64×64),
`TAG_W` 1..32 (default 8). Illegal static parameters elaborate a named missing
module and are unsupported. A frame contains `N=WIDTH*HEIGHT` pixels.

| Interface | Meaning |
| --- | --- |
| `begin_valid/begin_ready` | Accept a new frame only in IDLE. Latch `begin_rgb[23:0]`, `begin_depth[15:0]` and `begin_tag[TAG_W-1:0]`; clear all N locations and counters. Live BEGIN inputs afterward have no effect. |
| `s_valid/s_ready` | One ordered fragment. Ready only after clear and between completed fragment operations. There is no input queue. |
| `s_x,s_y[15:0]` | Unsigned integer pixel coordinates. Any x≥WIDTH or y≥HEIGHT is discarded before RAM access; full 16-bit coordinates are checked before address narrowing. |
| `s_rgb[23:0]` | Straight, unpremultiplied `{R8,G8,B8}` source color. Stored/output RGB uses the same packing. |
| `s_depth[15:0]` | Unsigned depth in caller-defined common units; smaller values are nearer. No interpolation, projection or depth-format conversion is performed. |
| `s_alpha[7:0]` | Exact 0..255 blend coverage; 0 preserves destination RGB and 255 replaces enabled channels. It is not Q8 unity=256. |
| `s_depth_func[1:0]` | 0 ALWAYS; 1 LESS (`source<stored`); 2 LEQUAL (`source<=stored`); 3 NEVER. |
| `s_depth_write` | Write source depth only on an in-bounds depth-passing fragment. Independent of alpha and RGB mask. |
| `s_color_write[2:0]` | Per-channel write enable, bit2 R / bit1 G / bit0 B. Disabled channels retain the destination exactly. |
| `end_valid/end_ready` | End a frame only in the fragment-ready phase. A held END waits for any accepted fragment to finish; on a simultaneous END and unaccepted fragment, END has priority and s_ready=0. |
| `m_valid/m_ready` | Complete raster export after END. `m_rgb[23:0]`, `m_depth[15:0]`, `m_x/m_y[7:0]`, `m_sof/m_eol/m_last` and `m_tag` remain stable while blocked. |
| `done_valid/done_ready` | Held completion after the final raster pixel transfers. No BEGIN or fragment is admitted until it is acknowledged. |
| `done_tag` | Original frame tag. |
| `done_seen,done_passed,done_oob[31:0]` | Accepted fragments, in-bounds depth-passing fragments, and out-of-bounds fragments. Each independently saturates at 2^32−1. |
| `done_count_overflow` | Sticky flag when any counter would increment beyond its maximum; cleared by BEGIN/reset. Saturation branches are source-reviewed, not driven through 2^32 events in finite simulation. |

Fragments need not follow raster order and may revisit one location arbitrarily.
Every accepted fragment snapshots all its fields. A subsequent same-address
fragment reads the committed preceding result; there is no read-after-write
bypass assumption or lost update. Rejected depth/OOB fragments write neither
RGB nor Z. A depth-passing fragment increments `done_passed` even if alpha 0
and all writes are masked; alpha 0 can still update depth when enabled.

BEGIN and END are explicit frame ownership transactions, not per-pixel SOF/LAST
signals. END must be sent after every intended fragment has handshaken; it does
not retroactively include a still-unaccepted fragment. END blocks additional
fragments as soon as the block returns to its ready phase. BEGIN during an
active frame is backpressured. No capture, drawing or export overlaps another
frame. Missing END or unbounded output/DONE backpressure can stall indefinitely.

Output order is x increasing within y increasing. SOF is asserted only on
pixel 0, EOL on each final column and LAST only on pixel N−1. Marker values and
payloads outside valid have no transaction meaning. `done_*` counters describe
the frame and are stable while DONE is held; they are diagnostics that may
change during drawing, not separately handshaken responses. There is no external
memory interface, host raster readback, stencil plane, MSAA or display timing.

## Exact blending and storage

For every enabled color channel on an in-bounds depth pass:

```
n = source*alpha + destination*(255-alpha)
result = floor((n+127)/255)
```

This is nearest rounding; denominator 255 is odd, so integer numerators cannot
land at an exact half. Intermediate precision is retained through the blend.
For all source/destination/alpha values, `0<=n<=65025`, so `t=n+127<=65152`.
In this range `floor(t/255)=(t+1+(t>>8))>>8` exactly. The RTL uses three signed
9×9 products `alpha*(source-destination)`, destination shift/subtract scaling,
and this bounded fold. There is no combinational divider, LUT table, hidden
approximation, gamma correction or premultiplied-alpha interpretation.
Rounding is once per channel per accepted passing fragment; blending is
ordered and not generally associative.

RAM stores packed `{Z16,RGB24}`. Clear, fragment read, fragment write and raster
read occupy disjoint FSM phases. Reads/writes are synchronous and RAM has no
reset loop. Fragment addresses are narrowed only after bounds checks establish
`0<=y*WIDTH+x<N`. No vendor primitive or external storage is required.

## Cycle schedule and architecture risk

With no external stalls, BEGIN is followed by N clear-write edges; first
fragment or END can transfer on edge N+1 after BEGIN. A depth-passing fragment
uses accepted input → synchronous read → depth/blend → write, giving II4.
Depth-rejected fragments give II3; OOB fragments give II1. There is no speculative
next-fragment acceptance. The commit precedes every later same-address read.

After an END transfer, output valid appears after one read edge and its first
transfer can occur on the second edge. Always-ready raster service is one
pixel every two edges, with successful DONE asserted after `2*N` edges from
END. Frame completion acknowledgement and the next BEGIN require separate
subsequent edges. Backpressure adds directly; these are RTL cycle counts,
not measured frequency, throughput or guaranteed real-time video service.

| Risk | Assessment |
| --- | --- |
| Default storage | 64×64×40=163840 bits (20 KiB). MEDIUM RAM inference/packing risk; packed 40-bit words may fragment BRAM. |
| Maximum storage | 128×128×40=655360 bits (80 KiB). **HIGH** target-device capacity risk; default suitability does not imply maximum fit. |
| Arithmetic | Three signed 9×9 multiplications and small add/fold logic, MEDIUM mapping/timing risk. DSP mapping and resource use are unmeasured. |
| Expected critical path | FTEST depth compare plus multiplier/add/fold or address/control routing; no measured timing result. |
| Integration | Single-clock serialized rendering and raster export. Producer/sink budgeting and physical scanout buffering remain system responsibilities. |

## Actual triangle integration

`example/triangle_depth64.sv`, top `triangle_depth64`, instantiates the unchanged
`../triangle_rgb_raster/rtl/triangle_rgb_raster.sv` and this store. Both use
ordinary ready/valid and synchronous active-high reset. Coordinates are zero
extended from 8 to 16 bits. `c_depth/c_alpha/c_depth_func/c_depth_write/c_color_write`
are snapshotted with each accepted triangle command; source colors and geometry
are handled by B33. Depth is **constant per triangle**, not interpolated, and
the example supplies no texture coordinate/sampling stage.

The adapter admits a triangle only after clear and while no primitive is owned.
It holds that ownership until `tri_done_valid && tri_done_ready`. END is blocked
through a pending primitive/completion; afterward the store's end_ready also
waits for its final fragment write. END has priority over a new triangle on
the same edge. Frame output uses BEGIN tag, while `tri_done_tag/status/count`
preserve each primitive's original B33 completion. Application software must
acknowledge primitive completion before ending the frame. Reset cancels both
halves together. The example does not alter B33 source or historical evidence.

Both source lists resolve from this package root. `files.f` contains the single
local production source. `example/files.f` additionally lists the existing
sibling triangle source once and the wrapper. Keeping that dependency path is
required when extracting the example; `B35_DELIVERY.json` records its exact
checked hash and archive. No new duplicate production triangle is introduced.

## Finite qualification

Run from repository root:

```
python -B cores/image_processing/fragment_rgb_depth_store/run_tests.py
```

Receipt: `reports/20261105T183457648821Z/results.json`. One preparation
attempt, no fixes/retries, all 10 planned children PASS, all 8 executable/file-list
and shared dependency inputs unchanged. Exact executable source copies
were frozen before numerical preparation; all generated vector files were
written before the first HDL tool launch. The runner requires successful
preparation, exact ordered check names, complete-suite flag, immutable inputs
and the exact simulator completion prefix; exit 0 alone is insufficient.
Each child has a 20-second watchdog and bounded 7-second cleanup; missing tools
produce NOT_RUN and any failure/timeout stops later launches. Offline tests use
only Python's standard library and local Icarus, with no network.

| Simulation | Checked output pixels | Scope |
| --- | --- | --- |
|1×1 / TAG1 |273 |264 source frames including all 256 alpha codes checked in separate clear/draw/export frames; protocol recovery |
|7×5 / TAG8 |595 |8 source frames, same-address RAW, all depth modes/equality, RGB/Z masks, OOB 65535 coordinates, random blending and reset recovery |
|128×128 / TAG32 |49152 |3 complete maximum-size clear/draw/export frames, last-address and OOB tests, random fragments |
|Actual triangle_depth64 chain |4096 |5 primitives: near red, occluded blue, partial-alpha green without Z write, equal-depth R-only overwrite, degenerate triangle; 18 passes from 24 fragments |

The first two store profiles each reset in all 8 active/held FSM phases plus
initial reset, with clean recovery exports. Tests check every raster word,
coordinate/marker/tag, counters, END exclusion, held raster/DONE stability,
busy BEGIN rejection and post-completion recovery. Total: 54,116 output word
comparisons and 18,066 output-stall cycles; no hardware timing assertion. The Python oracle uses ordinary
per-coordinate storage and direct integer weighted means rather than RTL
RAM/FSM/fold implementation. Its 65026-numerator fold invariant is a reference
check, not exhaustive RTL source/destination/alpha coverage. Compile warnings
are missing production timescales and existing B33 array sensitivity warnings.
No parameter sweep, full regression or hardware measurement is claimed.

Provenance/dedup: `SOURCES.md`, `references.json`. Qualification and exact
checked-to-delivered bridges: `QUALIFICATION.json`, `B35_DELIVERY.json`.

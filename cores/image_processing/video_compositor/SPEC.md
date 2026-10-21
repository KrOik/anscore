# IP-08 video composition and independent outputs (development)

Work-order target: multiple independent timing/frame counters, routing,
two-layer OSD with alpha/color-key, atomic safe-frame updates; one physical
display when connectable plus at least two parallel logical outputs verified
by CRC/timing. No simultaneous three physical RGB888 buses are required.
Current implementation establishes two-layer stream arithmetic, a separate
frame-safe configuration gate and independent logical raster timing. Their
integration into multiple composed pixel outputs is pending.

`rtl/dual_osd_stream.v` reuses unchanged canonical
`cores/system/common_scaffold/image/multiframe/img_mf_rgb_blend_pipe.v` twice.
RGB888 channels use exact integer rounding:
`(base*(256-alpha)+overlay*alpha+128)>>8`, alpha0..256. Layer0 blends onto
the base, then layer1 blends onto that result. Enabled color-key equality
makes that layer transparent. Disabled layers preserve their input. No
Gamma/linear-light blend is implied.

The interface is elastic valid/ready, RGB data and SOF/EOL/last/user/frame
metadata. Both overlay pixels/weights/enables are captured for each accepted
input pixel. Layer1 attributes travel through layer0's elastic metadata;
changing live inputs cannot misalign it under stalls. Output fields remain
stable under backpressure. Enabled alpha>256 sets error bit0; any error
blacks the pixel, preserves metadata, and propagates the8-bit error tag.
Reset discards all pipeline contents. Whole-frame marker/size validation and
global configuration are the owning scheduler's responsibility, not hidden
in this per-pixel module.

```
. ./scripts/env.ps1
python cores/image_processing/video_compositor/tools/test_dual_osd.py
```

Current simulation compares1024pixels and every metadata/error field against
an independent Python integer model. It covers both enables, color-key hits
and misses, alpha0/1/255/256 and invalid257/511, seeded input gaps/output
stalls, high-bit frame IDs and held outputs. First128pixels are continuously
submitted with no sink stall; the test asserts one output per clock after
initial fill. This is module II1, not whole-display throughput or routedFmax.

Reuse candidates reviewed: canonical runtime `video_timing_generator.sv`,
`sys_frame_switch4`, `sys_atomic_config`; the existing command-serialized
`cip_image_osd` uses the same blend primitive but its command/marker contract
must not be silently replaced. No shared canonical files have been edited.

`rtl/frame_atomic_config.v` reuses unchanged `sys_atomic_config` and gates
the input stream at frame boundaries. It carries generic DATA_W payload,
SOF and frame-LAST (not EOL). All OSD metadata may be packed in that payload.
The active configuration belongs to every accepted pixel of a frame; downstream
pipelines must capture it with each pixel, as dual_osd_stream does. This is
one clock domain, with no pixel buffering. Each output needs its own instance.
Pending commits block shadow writes and apply after accepted LAST, inserting
one boundary cycle. Same-edge write/commit is included. A first pixel already
presented under backpressure locks the old configuration until its LAST.
Missing/nested SOF sets a sticky framing diagnostic; missing LAST retains
ownership until reset or an eventual LAST. Reset discards pending state.
Run `python cores/image_processing/video_compositor/tools/test_frame_config.py` for
directed boundary, stalled-head/tail, partial-write, queued commit, single-pixel,
framing-error and reset checks. This gate is not yet wired to a board top.

`rtl/multi_output_timing.v` instantiates unchanged canonical
`video_timing_generator` per output (default three). All outputs share a clock
but have independent pixel_tick, configuration, start/stop/abort/done and
sync polarity. Packed buses place output0 in the least-significant slice.
Timing configuration is latched at start; restart requires idle/done ACK.
Start arms the timer and a later pixel tick starts running. Coordinates and
sync/DE levels persist between ticks; consume pixel/marker events only when
running AND pixel_tick. There is no downstream ready on a physical raster.
Stop and abort both finish at the total-raster frame boundary per the canonical
timer; abort reports code3, invalid configuration code1. This is not an
immediate emergency blanking circuit.

Per-output 32-bit completed-raster-frame and 64-bit active-pixel/total-tick
counters increment on sampled ticks only and wrap modulo their widths.
An accepted start resets only that output's counters, including invalid starts.
Counts exclude the arming tick and include active/blanking ticks while running.
These live buses require a snapshot adapter before asynchronous host readout.
No cross-clock display clock synthesis or PHY is included.

`python cores/image_processing/video_compositor/tools/test_multi_timing.py` runs three
different rasters at tick divisors1/2/3. The independent Python oracle checks
every logged coordinate, sync polarity/porch, DE/SOF/EOL/EOF/frame-end and
all counters, including one output's stop/restart and another's abort,
invalid zero-width configuration and recovery while output0 keeps running.

`rtl/video_frame_crc.v` passively monitors valid AND ready pixels. CRC is
CRC-32/ISO-HDLC (initial ffffffff, reflected edb88320, final complement),
three bytes per RGB888 pixel in B,G,R order, excluding metadata and blanking.
Accepted SOF initializes a frame; accepted LAST emits a one-cycle result_valid
with frame ID, CRC, count and error bits: bit0 missing/nested SOF or changed
frame ID; bit1 any nonzero pixel error; bit2 pixel count differs from
expected_pixels on LAST. Set expected_pixels consistently for the whole frame.
Nested SOF resynchronizes CRC/count to the new SOF and diagnoses framing.
Result data persists until the next LAST; result_valid is a pulse, not a held
host handshake. Reset discards incomplete frames and results. This monitor
does not check EOL/line dimensions or force a missing-LAST timeout.

`python cores/image_processing/video_compositor/tools/test_parallel_crc.py` connects
three real dual_osd_stream instances to three CRC monitors with independent
seeded input gaps and sink stalls. It compares768pixels/all metadata and
24frame CRCs against independent integer blending/Python zlib. A separate
monitor test checks seven missing/nested SOF, frame-ID change, count mismatch,
pixel error, stalled LAST and reset/recovery results with exact zlib CRCs.
These are parallel elastic streams, not yet timing-driven display scanout.

`rtl/raster_osd_output.v` integrates a canonical timing generator, eight-word
atomic config, dual OSD and frame CRC as one logical scanout. Instantiate per
output; all signals remain in one clock domain. Every running pixel_tick
(active or blanking) enters the six-register OSD pipeline with HS/VS/DE and
configuration version in its metadata. Output pixel_valid pulses exactly six
system clocks later; sample sync/RGB only on pixel_valid. Blanking RGB is zero.
There is no sink backpressure; unexpected source non-ready sets sticky overflow.
Restart is gated until the prior six pipeline stages drain. Host completion
must also account for CRC publication rather than treating timer done as CRC ACK.

Config words: 0 baseRGB,1 overlay0RGB,2 overlay1RGB,3 alpha0[8:0]/alpha1[24:16],
4 layer enables[1:0]/key enables[3:2]/source mode[9:8],5 key0,6 key1,7 reserved.
Source mode0 solid,1 baseRGB XOR {x[7:0],y[7:0],frame[7:0]},2 grayscale
(x+y modulo256); mode3 currently aliases solid. These are internal reference
sources, not yet external-video routing. Commit applies when idle or on the
last total-raster tick, so active configuration is constant for every frame.
Each pixel snapshots both layer controls; no need to drain to apply between
frames. The separate frame_atomic_config gate remains available for elastic
sources and is not inserted into an unstallable raster. Frame IDs reset on
accepted start; output version carries the low13 bits of config_version.
CRC expected active size is latched at start; timing updates require restart.

`python cores/image_processing/video_compositor/tools/test_raster_osd.py` instantiates
three real scanouts with distinct widths and pixel tick divisors1/2/3.
Independent Python checks every output pixel/sync/marker/version/error against
the expected raster and exact two-layer arithmetic, fixed six-clock latency,
zlib per-frame CRC, a lane0 mid-frame commit becoming visible on frame3, and
frame-boundary stops/drain. No PHY pins or generated display clock are claimed.

`rtl/video_route4.v` routes four elastic RGB888 sources to four elastic sinks
using unchanged `sys_frame_switch4` frame-locked round-robin arbitration.
Every source has a separate two-word frame_atomic_config bank: word0[1:0]
destination, remaining bits/word1 reserved. Reset destination is0. Writes and
commits are per source; a mid-frame route change applies before its next frame.
The canonical switch is combinational once ownership is acquired, with no
storage; a source-index tag selects the corresponding stable full-width
frame32/user16/SOF/EOL sideband while RGB24/error8 travel through its data bus.
Any future switch buffering requires changing this sideband scheme. Frame-LAST
is distinct from EOL. All fields must hold during valid&&!ready. Framing-error
is sticky per source. Arbitration acquisition introduces frame-boundary gaps;
this router is not an unstallable physical raster output or a frame buffer.

`python cores/image_processing/video_compositor/tools/test_video_route.py` verifies
four sources, initial destination contention, independent seeded gaps/stalls,
mid-frame route commits,336pixels/32frames, all metadata and exact per-source
ordering. RTL assertions check stable output fields/valid while stalled; the
Python oracle checks no destination interleaves owners within a frame.

`rtl/video_results_csr.v` provides three held result snapshots with explicit
per-lane ACK and dropped-result counts; see RESULTS_CSR.md. Raster CRC outputs
now include crc_version latched from the same accepted LAST as that result.
`rtl/video_control.v` wires all three scanouts to these result producers and
adds runtime timing,dividers,finite frame targets,layer configuration and
start/stop/abort control; see CONTROL_CSR.md and tools/test_control.py.

Remaining: external-source buffering into scanout, physical transport/host control,
CSR/probe/board binding,25K synthesis/P&R, conditional physical display and
hard-JTAG/LA evidence, dependency/license audit and release files. No physical
display,25K build or L3/L5 release result is claimed for this project yet.

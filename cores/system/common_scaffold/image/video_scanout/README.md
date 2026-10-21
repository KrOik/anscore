# Runtime video timing and synchronous-FIFO RGB scanout

`video_timing_generator` adds runtime configuration, independent pixel tick,
frame-boundary start/stop and explicit status to the repository's video timing
capabilities. The existing `display/src/lcd_timing.v` is a real static-parameter
LCD timing implementation and is preserved. `video_rgb_scanout` is a new
RGB888 pixel-marker stream to fixed-tick RGB/HSYNC/VSYNC/DE bridge. Neither
module creates clocks, drives TMDS, encodes HDMI packets or crosses clock domains.

## Timing ABI

Parameters `MAX_ACTIVE=4096` (legal 1..4096), `MAX_TOTAL=8192` (legal 1..65535).
Ports `clk,rst_n,ce,pixel_tick,start_valid/start_ready,stop,abort,
done_valid/done_ready,frame_error,error_code[7:0]`. Runtime 16-bit fields:
`cfg_h_active, cfg_h_front, cfg_h_sync, cfg_h_back` and matching `cfg_v_*`.
`cfg_hsync_positive,cfg_vsync_positive` select pulse polarity. Active and sync
lengths must be nonzero; front/back porch can be zero. Active dimensions must
fit MAX_ACTIVE; each sum of all four components must fit MAX_TOTAL. Sum checks
are widened and reject 16-bit overflow, rather than silently truncating it.

Outputs `running,h_count[15:0],v_count[15:0],hsync,vsync,de,sof,eol,eof,frame_end`.
Scan order is active, front porch, sync pulse, back porch; (0,0) is the first
active pixel. SOF/EOL/EOF mark first active pixel, each active row's final pixel
and frame's final active pixel. `frame_end` marks the final tick of the **whole
timing frame**, including blanking. Markers qualify with pixel_tick; they are
levels held with counters between ticks, not unconditionally one-clock pulses.
Sync pins have inactive configured polarity when idle.

START snapshots configuration with CE&&VALID&&READY, then arms the job. Running
begins on a subsequent pixel_tick boundary. Busy configuration changes have no
effect. Once running, **pixel_tick advances timing even while CE=0**. No input
pixel/FIFO event, consumer ready or error can pause a scan line. Stop is a
CE-qualified request to finish at the next complete timing-frame boundary,
including a request on that final tick. Abort does the same with error 3.
Stop/abort while armed can cancel before any physical frame begins. DONE holds
until CE-qualified acknowledgment, then a new configuration may be accepted.
Invalid configuration reports error 1 without starting physical timing. Reset is
synchronous active-low, overrides CE, and immediately resets/cancels the job.
The upstream system supplies an appropriate pixel clock/tick rate; nominal
VGA/720p/1080p frame frequency is not inferred from geometry or synthesized here.

## Scanout ABI and failure behavior

Same timing/status ports and parameters, plus `FIFO_DEPTH=64` (2..4096) and
`PREBUFFER=16` (1..FIFO_DEPTH). Input `s_pixel[23:0]` is RRGGBB with
`s_valid/s_ready,s_sof,s_eol,s_last`; input transfers require CE&&VALID&&READY.
It is **not AXI**. Output `rgb[23:0]` is opaque RGB888, with the timing ports
above. Physical output transfers/sample points are pixel_tick, independent of CE.

A synchronous block-RAM-compatible FIFO plus one registered lookahead item
decouples the input from the fixed tick. Input backpressure prevents overflow;
the FIFO never silently overwrites a pixel. Full-ring refill waits until the
next clock after prefetch, avoiding same-address BRAM read/write collisions.
This backpressures only the source, never physical timing. In PREFILL, no timing frame runs
until at least PREBUFFER accepted pixels are buffered. The FIFO stage has
FIFO_DEPTH items plus one lookahead register. The producer must obey READY,
provide enough data during active scan and supply markers for each complete
configured input frame. Accepted inputs can run across multiple frames.

On every active pixel tick, one buffered pixel is consumed. Empty FIFO never
reuses an old pixel: RGB becomes black, error 4 is latched and the remainder of
the current physical frame stays black with unchanged valid timing. Marker
errors report error 2; abort reports error 3. Both discard queued unexposed
pixels, black the remainder and finish at a frame boundary. Invalid static or
runtime configuration is error 1. Faults before timing launch can end without
emitting any frame. Error is sticky until a new START; later abort does not
rewrite an already reported error. The complete partial image is invalid on any
error, including already displayed pixels. There is no automatic search for
another SOF or silent data recovery; acknowledge DONE and restart explicitly.

Marker faults accepted on the final timing tick request stop in that same cycle,
so no extra physical frame is emitted. Ten directed boundary cases cover
marker/stop/abort coincidences and active underflow. For faults first observed
in the same cycle, priority is abort, underflow, marker, then graceful stop;
an error latched earlier remains sticky. Positive sync lengths make an active
underflow on the whole-frame final tick unreachable for legal geometry.

Graceful stop continues accepting and scanning pixels needed for the current
physical frame. The source must continue servicing READY; failure to provide
required pixels still reports underflow. At completion the FIFO is flushed,
including any prefetched future-frame data. Stop during PREFILL flushes the
pending frame without starting timing. Abort/reset also flush the queue, with
reset permitted to cancel immediately. No separate hidden host-side flush or
frame-memory allocation is used. Blanking RGB is always zero.

## Verification and references

```
python -B cores/system/common_scaffold/image/video_scanout/test_timing_case.py
python -B cores/system/common_scaffold/image/video_scanout/test_scanout_case.py
python -B cores/system/common_scaffold/image/video_scanout/test_timing.py
python -B cores/system/common_scaffold/image/video_scanout/test_scanout.py
python -B cores/system/common_scaffold/image/video_scanout/test_timing_protocol.py
python -B cores/system/common_scaffold/image/video_scanout/test_protocol.py
python -B cores/system/common_scaffold/image/video_scanout/test_parameters.py
python -B cores/system/common_scaffold/image/video_scanout/test_dense_numeric.py
python -B cores/system/common_scaffold/image/video_scanout/test_fault_boundaries.py
python -B cores/system/common_scaffold/image/video_scanout/synth.py
```

Narrow CASE entries cover each module separately. Full timing tests independently
derive every tick's coordinates, HSYNC/VSYNC/DE and markers from ordinal division
and constant format geometry, not DUT counters. They check complete two-frame
VGA640x480 (800x525), 720p1280x720 (1650x750), 1080p1920x1080 (2200x1125),
and minimum zero-porch configurations, both polarities, CE-off advancement,
nonuniform pixel ticks and configuration capture. This covers 8,265,008 ticks.

The scanout test is a real hardware timing-generator→synchronous-FIFO→RGB chain,
with every physical pixel checked against a separate deterministic data oracle,
including timing/blanking and CE-off output. Four profiles include complete
VGA frames, eight frames / 618,904 active pixels. Dense tests add full-rate
pixel_tick=1 scans and maximum legal active width/height 4096; another timing
test covers maximum total65535. Fault tests cover prebuffer, stalled/full input,
underflow, malformed markers, abort, frame-boundary stop, reset under CE=0,
error retention, held DONE and healthy restart. Static parameter invalid profiles
are explicitly tested. These are simulation and isolated synthesis claims,
not board output, routed timing or display electrical compliance.

`synthesis.json` contains per-module default and maximum static profile cells,
LUT+ALU+MUX+4*RAM16SDP4, DSP and conservative BRAM9 totals (every block RAM
primitive counts twice), plus actual report hashes. All profiles fit 15K LUT,
4 DSP and 46 BRAM9. Timing uses 666/675 LUT-class (default/MAX_TOTAL65535),
0 DSP, 0 BRAM9. Scanout uses 1163/1249 LUT-class (default/FIFO4096),
0 DSP and 2/12 BRAM9 respectively. RAM is synchronously read and never expanded into an
asynchronous full-frame coefficient/pixel array. No full-resolution frame RAM.
All simulator/vectors/download payloads are temporary or memory-only; retained
logs and source-bound JSON reports are small reproducible evidence.

Actual network references in `references.json`: Project F's video timing guide
with standard VGA/720p/1080p timing tables, and its separately developed mature
display_timings RTL. These are not substituted for electrical certification.
URLs, content SHA256, response sizes and excerpts are retained; this is original
RTL, not a verbatim copy of the reference implementation.

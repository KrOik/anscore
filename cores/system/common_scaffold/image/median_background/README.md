# Previous-frame temporal median background model

`temporal_median_background.sv` implements a true per-pixel temporal median
background model, distinct from the repository's EWMA model. For each unsigned
8..16-bit pixel, it reads the same coordinate from the previous WINDOW=3 or 5
completed frames, computes their exact middle order statistic, and reports
foreground iff `abs(current-background) > threshold`. Equality is background.
The threshold is a full unsigned BITS-bit runtime value, committed only at a
frame boundary through cfg_valid/cfg_ready; reset default is zero.

The current frame **never participates in its own reference median**. Every
pixel's historical values are read before the current pixel overwrites that
coordinate in the ring slot. Other coordinates are disjoint, so overwriting
processed coordinates cannot affect later pixels in that frame. The ring slot
rotates only after the final output of the frame is accepted. Thus accepted
input at the last coordinate alone cannot prematurely rotate history while
its output is stalled.

## Warmup and fault recovery

The first WINDOW complete frames after reset or an aborted frame have
m_warmup=1, m_background=0 and m_foreground=0. They still populate the history
and emit one output per input pixel. Frame WINDOW+1 is the first frame with a
valid historical median. The zero warmup background is an explicit placeholder,
not a partial-history median. The full-frame completed count changes only at
the last output handshake, keeping warmup consistent throughout the frame.

SOF must be exactly at (0,0), EOL exactly on each row's last pixel. A malformed
accepted beat sets error_code=1, pulses done, aborts the frame and returns idle.
Any partial ring writes are invalidated by resetting the completed-frame count
and ring slot; RAM is deliberately not cleared. A fresh WINDOW complete-frame
warmup overwrites every slot before history becomes valid again. Previously
emitted pixels from the aborted frame must be discarded by the frame consumer.
Discard the rest of that input frame externally and restart with fresh SOF;
the core does not search for markers or consume a discarded remainder.
error_code clears on reset or the next accepted first pixel.

Reset is synchronous active-low and overrides CE. It aborts any pending output,
clears threshold/config/status and invalidates all history without a RAM-clear
loop. An output-stalled COMPUTE may already have overwritten a ring coordinate;
reset's mandatory full warmup prevents that partial frame from becoming a
future declared-valid reference. done pulses on frame completion or marker
failure, for one enabled cycle. cfg_done also lasts one enabled cycle.

## Streaming and storage

Geometry is positive static WIDTH/HEIGHT. Input and output are row-major;
output includes background, foreground, warmup and SOF/EOL. All transfers
require **ce && valid && ready**; both neighbors must honor CE. Output valid
and payload remain stable through CE pauses and backpressure. A pending
configuration at idle delays the next first input, while a request during a
frame cannot prevent the frame from finishing. Hold configuration stable until
its handshake. busy includes processing and partial frame capture; idle occurs
only between frames.

One synchronous-read history RAM stores WINDOW*WIDTH*HEIGHT*BITS bits. A single
registered read port fetches the WINDOW previous values sequentially; a narrow
sorting network finds the median. No frame RAM reset, division or DSP is used.
First output valid appears 2*WINDOW+1 enabled edges after its input acceptance;
the earliest handshake is the next edge. Input/output pixel pitch without
stalls is 2*WINDOW+3 enabled cycles (9 for WINDOW3, 13 for WINDOW5). This is a
bounded sequential implementation, not an II=1 temporal video filter.

## Verification

```
python -B cores/system/common_scaffold/image/median_background/test_median_background.py
python -B cores/system/common_scaffold/image/median_background/synth.py
```

An independent Python list-of-completed-frames oracle checks 147 frames and
2118 pixels across 1x1, 1x5, 5x1, 3x5 and 8x6, BITS 8/10/12/16 and both
window sizes. Scenarios include constant background, moving bright/dark points,
unsigned extremes/random values, threshold equality and dynamic thresholds
10/maximum/zero. Tests deliberately overwrite part of trained history, then
inject a bad frame or reset a stalled output; all subsequent warmup and
declared-valid history are checked from a fresh oracle. Random valid gaps,
ready stalls, CE pauses, output stability, done/error and five illegal parameter
variants are covered. Temporary binaries are removed automatically.

Default 8x6/8-bit isolated Gowin synthesis (`-noalu -nodsp`) reports:

| WINDOW | LUT1-4 | MUX5 / MUX6 | FF | memory | DSP |
| --- | ---: | ---: | ---: | --- | ---: |
| 3 | 617 | 48 / 1 | 227 | 18 RAM16SDP4 | 0 |
| 5 | 700 | 55 / 0 | 235 | 1 DPX9B | 0 |

Both CHECK passes report zero problems. Memory scales with image geometry.
No P&R, clock target, board or scene-quality conclusion is claimed. Objects
persisting for a majority of the history window naturally become background;
no foreground-selective update gate or illumination compensation is included.

# Exact binary Manhattan / chessboard distance transform

`binary_distance_transform.sv` computes distance from each binary foreground
pixel (1) to the nearest **in-frame background pixel (0)**. Background outputs
zero. Mode 0 is exact Manhattan L1 (four-neighbor distance); mode 1 is exact
chessboard L-infinity (eight-neighbor distance). This is not Euclidean distance,
nor a chamfer approximation advertised as Euclidean.

Static WIDTH/HEIGHT must be positive. DIST_W defaults to ceil(log2(W+H+1))
and must be at least that wide, so every finite distance (at most W+H-2)
fits exactly. The all-ones distance is reserved as INF. Image borders are
**not implicit background**. For an all-foreground frame, no_seed is asserted,
every output has m_invalid=1 and distance=INF. No finite result saturates.
The invalid sentinel remains INF through neighbor additions, avoiding wrap.

The core captures a frame into one synchronous-read distance RAM, initializes
foreground to INF and background to zero, then performs forward/backward
raster sweeps. Forward uses left/up (and upper diagonals for chessboard),
backward uses right/down (and lower diagonals). Each pixel compares its current
value with each valid neighbor+1, with out-of-bounds neighbors treated as INF.
Those two standard directional sweeps are exact for the specified unobstructed
grid metrics. Storage is WIDTH*HEIGHT*DIST_W bits plus scalar state.

## Interface contract

Input/output are row-major. s_sof must be asserted exactly on pixel(0,0),
s_eol exactly on the final pixel of every line. Output markers track output
coordinates, not processing phases. Missing or mispositioned markers latch
error_code=1 and enter fail-stop (no further input/output until reset).
Reset discards the partial frame; there is no timeout or automatic re-sync.

cfg_chessboard commits on cfg_valid&&cfg_ready only when idle between frames;
cfg_done pulses for one enabled cycle. Reset default is Manhattan. A pending
configuration delays the next first pixel, but a request arriving mid-frame
does not block completion of that frame. Hold configuration stable until its
handshake. Geometry remains static. busy includes capture, sweeps and output.
no_seed reports the last completed capture, remains available through output,
and clears on the next first input or reset.

All transfers require **ce && valid && ready**. CE is shared with both
neighbors. Output valid/payload/markers/invalid stay stable through CE pauses
and backpressure. Synchronous active-low reset overrides CE, discards pending
output/configuration, clears errors and restores Manhattan mode. The RAM is
not reset because each frame overwrites it before reading. Frames do not
overlap: next input starts only after all outputs have drained.

Let N=WIDTH*HEIGHT. Arithmetic sweeps take 14*N enabled cycles for Manhattan,
22*N for chessboard after the final input handshake. First output valid appears
two enabled edges later. Output II=3 enabled cycles without stalls. Input
capture can accept one pixel per enabled cycle. This intentionally bounded
sequential implementation makes no II=1 full-frame processing claim.

## Evidence

```
python -B cores/system/common_scaffold/image/distance_transform/test_distance.py
python -B cores/system/common_scaffold/image/distance_transform/synth.py
```

An independent multi-source Python BFS oracle uses four/eight undirected
neighbors rather than the RTL sweeps. Six geometries (1x1, 1x7, 8x1, 3x5,
8x6, 7x7) cover both modes, zero/foreground-only, edge/center seeds and random
patterns: 72 frames, 1536 outputs. Tests exercise valid gaps, ready stalls,
CE pauses, output stability, per-frame modes, no-seed sentinels, missing SOF,
wrong EOL, sticky fail-stop, partial-frame reset and reset with CE disabled.
Invalid WIDTH, HEIGHT and undersized DIST_W are rejected. Temporary binaries
are automatically removed; bounded JSON evidence and synthesis logs remain.

Default 8x6 isolated Gowin synthesis (`-noalu -nodsp`) reports 496 LUT1-4,
47 MUX2_LUT5, 92 FF, 12 RAM16SDP4 and zero DSP; CHECK reports zero problems.
Storage scales with frame geometry. No P&R, clock target or board validation
is claimed.

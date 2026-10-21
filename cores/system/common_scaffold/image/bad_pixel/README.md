# Bayer dynamic bad-pixel correction

`raw_bad_pixel_frame.sv` performs dynamic hot/dead pixel detection and
replacement on a single-plane Bayer raster. Its eight neighbors have offsets
(-2,-2), (0,-2), (2,-2), (-2,0), (2,0), (-2,2), (0,2), (2,2).
These positions share the center's Bayer phase for all four Bayer patterns.
Sort the eight samples, take floor((sample[3]+sample[4])/2), and replace
the center only when abs(center-median) is strictly greater than threshold.
Output m_corrected identifies replacement. A two-pixel border passes through.
This is dynamic median-based correction; there is no calibrated defect map,
cluster-reconstruction mode, edge-directed predictor or sensor integration.

BITS accepts 8 through 16 inclusive; WIDTH/HEIGHT are positive, at most 4096,
with WIDTH*HEIGHT <=65536. Geometry is static. Runtime threshold is accepted
using cfg_valid/cfg_ready only before a frame and persists until reconfigured
or reset (reset threshold is zero). Configuration takes priority over pixels.
All transfers require ce && valid && ready; reset is synchronous active-low.

Pixels arrive through s_data/s_valid/s_ready, with SOF on the first sample
and EOL on each row's final sample. Capture completes before any output.
A marker mismatch discards the frame with frame_error and done_valid; no
partial raster is emitted. Discard the remainder of that malformed input,
acknowledge done, then start a fresh frame. Output m_data/m_corrected and
m_sof/m_eol hold under stalls. done_valid stays asserted until done_ready
is accepted. Reset aborts capture, processing, output or result waiting.

Synchronous frame RAM uses WIDTH*HEIGHT*BITS storage bits. Additional storage
is eight BITS-wide neighbor registers plus arithmetic/control. Each interior
pixel uses serial synchronous reads and 28 adjacent compare/swap cycles.
Memory contents do not need reset: a complete valid capture overwrites them.
The design favors small arithmetic area and does not promise continuous
camera-rate throughput or a qualified maximum clock.

Run from the repository root:

```powershell
python -B cores/system/common_scaffold/image/bad_pixel/run_tests.py
python -B cores/system/common_scaffold/image/bad_pixel/synth.py
```

Independent Python sorted-neighbor oracle: 42 frames / 2289 pixels across
seven geometries/widths (8,10,12,16 bits). Tests cover hot/dead pixels,
strict threshold equality, phase-separated patterns, median floor rounding,
random/max-threshold data, thin images, backpressure/CE, markers, bad-frame recovery without reset, and reset.
Regression vectors and executables use TemporaryDirectory and are removed.

Default 16x16/12-bit isolated Gowin synthesis (-noalu -nodsp): 727 LUT1..4,
78 MUX5, 251 FF, 1 DPX9B, 0 DSP, check -assert PASS. Evidence:
`../../evidence/bad_pixel_synth_20261018T185710Z_f2e90893`.
Functional evidence: `../../evidence/bad_pixel_20261018T190023Z_39f00c59`.
No board acceptance, timing signoff or image-quality qualification.

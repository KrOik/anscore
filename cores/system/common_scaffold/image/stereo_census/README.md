# Rectified Census stereo matching

`stereo_census_match_frame.sv` accepts paired left/right Census rasters and
per-pixel border flags, and outputs a left-reference integer disparity map.
The images must already be rectified and synchronized. For left coordinate
(x,y), candidates are right(x-d,y), with d in 0..min(MAX_DISPARITY,x).
The score is descriptor XOR popcount (Hamming distance). Search never wraps
across rows. Candidates marked right-border are excluded; a left-border
pixel has no candidates. Equal scores select the smallest disparity.

The second-best score includes every remaining candidate, including equal
scores and adjacent disparities. m_invalid is true when there is no candidate,
the best score exceeds cfg_max_cost, or cfg_uniqueness is nonzero and
second_best-best < cfg_uniqueness. A single candidate passes uniqueness.
Thus uniqueness is an absolute cost gap, not a percentage or an excluded
neighborhood rule. Setting zero disables that check. Threshold equality passes.
No candidates produces disparity=0 and cost=DESC_BITS+1 (INF). On other
invalid outputs, the best disparity and cost remain available for inspection.

Parameters: positive WIDTH/HEIGHT <=4096; WIDTH*HEIGHT<=65536;
DESC_BITS=1..64; MAX_DISPARITY=0..4095. Cost and disparity port widths are
derived automatically; overrides may increase but must not reduce them.
cfg_max_cost/cfg_uniqueness are accepted together before each frame through
cfg_valid/cfg_ready, persist across frames, and reset to DESC_BITS/zero.
Configuration has priority over pixels. Full COST_BITS-range config values
are accepted; a maximum cost larger than DESC_BITS admits all finite costs.

Input s_left/s_right and s_left_border/s_right_border share one s_valid/s_ready
transaction, so the caller must pair coordinates before delivery. SOF marks
the first sample; EOL marks each row's end. Capture completes before search.
Marker mismatch emits frame_error and done_valid without any output raster.
Discard the remainder of malformed input, acknowledge done, then restart.
Output m_disparity/m_cost/m_invalid has m_valid/m_ready plus raster SOF/EOL.
Every handshake requires ce && valid && ready; payloads hold during stalls.
Synchronous active-low reset aborts any current transaction. done_valid stays
asserted until done_ready is accepted.

Two synchronous frame arrays store 2*WIDTH*HEIGHT*(DESC_BITS+1) bits.
Each non-border pixel uses a left read, a control cycle, two cycles per
candidate, one result cycle and an output transfer; pauses add latency.
This serial winner-takes-all matcher has no spatial cost aggregation, SGM,
left/right consistency, subpixel interpolation, calibrated depth conversion
or real-time video throughput claim. It is a complete bounded integer
matching stage, not a complete stereo camera product.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/stereo_census/run_tests.py
python -B cores/system/common_scaffold/image/stereo_census/synth.py
```

Independent all-candidate Python oracle: 87 descriptor frames / 1397 outputs
across 1/8/24/32/64-bit inputs, zero disparity range, range beyond row width,
ties, max-distance matches, absolute uniqueness, random border masks,
known shifts, CE/backpressure, malformed frames, recovery and reset.
Two further end-to-end profiles instantiate two actual img_census_frame RTL
cores feeding this matcher: eight paired grayscale frames / 720 disparities
for 3x3 and 5x5 Census, including shifted random scenes and a constant scene.
Expected descriptors and disparity/cost/invalid outputs come from independent
numerical models. Combined: 95 frames / 2117 outputs. Temporary binaries and
vectors are deleted. Evidence:
`../../evidence/stereo_census_20261018T191109Z_2a1e28ec`.

Default 16x8/24-bit/max-disparity7 isolated Gowin synthesis (-noalu -nodsp):
584 LUT1..4, 56 MUX5, 158 FF, 400 RAM16SDP4 distributed RAM primitives,
no block RAM or DSP. check -assert PASS. Memory mapping depends on geometry.
Evidence: `../../evidence/stereo_census_synth_20261018T190949Z_f094df1a`.
No board acceptance, timing signoff or stereo image-quality qualification.

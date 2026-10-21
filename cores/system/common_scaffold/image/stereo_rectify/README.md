# Host-map stereo rectification / general remap sampler

`stereo_rectify.sv` implements actual inverse-map frame sampling. A host loads one signed24 **Q16.8** source-coordinate pair for every destination pixel; the core captures a complete source frame into synchronous RAM, reads four source taps synchronously, performs normalized bilinear interpolation and emits a destination raster. The map may express calibrated lens distortion, rectification, perspective or another arbitrary inverse warp. **This module does not estimate camera calibration or generate maps.** Use separate instances/maps for left and right cameras, or time-share one instance and atomically replace maps between frames. A single instance processes one scalar channel; RGB uses independent channels or an external channel scheduler.

## Geometry, data and interpolation

Static SRC_WIDTH/SRC_HEIGHT and DST_WIDTH/DST_HEIGHT may differ, each1..256. BITS is8,10 or12. Defaults are16x12 source/destination and8bit pixels. The source range is0..2^BITS-1; map coordinate range is[-32768,32767.99609375], with negative values handled by arithmetic floor and nonnegative fractional remainders. Every output position has an explicit map pair in raster order; there are no hidden identity defaults.

Default **CV_COMPAT=0** preserves all8 fractional map bits. For x=i+fx/256 and y=j+fy/256, taps are (i,j),(i+1,j),(i,j+1),(i+1,j+1), with weights (256-fx)*(256-fy), fx*(256-fy), (256-fx)*fy, fx*fy. Sum is rounded once by adding32768 then shifting16. CV_COMPAT=1 first rounds each Q8 coordinate to the nearest Q5 phase, ties to even (including negative coordinates), then uses analogous32-based weights. This option explicitly matches the **fixed-map** phase table used by OpenCV convertMaps, rather than claiming all OpenCV paths quantize identically.

Every tap outside the source rectangle is independently replaced with frame-snapshotted cfg_fill, matching BORDER_CONSTANT. A partially outside footprint therefore mixes source and fill. m_in_bounds is true iff every **nonzero-weight** tap is inside; zero-weight outside taps do not invalidate exact integer samples on the final row/column. Fully outside coordinates produce cfg_fill. In CV_COMPAT mode this flag describes the phase-quantized footprint. Invalid status does not force an otherwise partially valid interpolation entirely to fill.

Weights are nonnegative and sum to2^(2F), F=8 or5. Thus output remains in the pixel/fill range without saturation. With P=2^BITS-1, weighted sum is <=P*2^(2F), and the rounding term is2^(2F-1); BITS+18-bit arithmetic safely covers the worst BITS12/F8 case. Coordinate/tap arithmetic is signed24/25 and includes the one-pixel neighbor without wrapping extreme map values into RAM. RAM is accessed only for explicitly in-range taps.

## Atomic map protocol

Map traffic uses enabled valid/ready edges:

1. map_begin_valid/map_begin_ready starts writing the **inactive** bank, resets its sequential index, and clears map terminal status. The active bank remains usable.
2. map_x/map_y plus map_valid/map_ready loads exactly DST_WIDTH*DST_HEIGHT pairs. map_last must be false except on the last pair. No random-address write interface exists, so duplicate/missing addresses cannot be silently committed.
3. After accepting the final pair, map_commit_valid/map_commit_ready atomically publishes the complete inactive bank. Commit readiness is limited to frame IDLE; a commit may be held while a frame or its held DONE is active. The current frame's bank is snapshotted on START and cannot change mid-frame.
4. map_done_valid/map_done_ready holds success or error, with map_done_error/map_error_code. Acknowledge before another map_begin. A failed load/commit/abort leaves the previous active map valid and unchanged.

Inactive-map loading may overlap frame capture/replay. Commit and frame START cannot both transfer on the same edge; an accepted commit takes priority, and the following START uses the new bank. An early commit is accepted only when frame idle, reports incomplete-map error82, and retains the old map. Assert commit after the final map-data handshake, not concurrently with it: commit validity suppresses map_ready. A wrong map_last fails immediately with81. map_abort cancels loading/complete inactive maps with93 on an enabled edge, but does not invalidate the active map or affect held map DONE. While idle, map_begin is independent of frame start and does not itself alter the active map.

## Frame and error protocol

Control is clk/rst_n/ce, start_valid/start_ready, abort; input pixels use s_data/s_valid/s_ready/s_sof/s_eol/s_last. Input markers must identify the first source pixel, each source row end and final source pixel exactly. Markers fail immediately, even during partial capture; the caller need not finish a malformed frame. Source and map RAM contents are not reset, but an accepted healthy frame overwrites every source pixel before replay. START without an active map returns82. Static unsupported parameters return80.

Output m_data/m_valid/m_ready plus m_sof/m_eol/m_last/m_in_bounds is the destination raster. done_valid/done_ready/done_error/error_code holds terminal frame status. Both output and DONE hold under backpressure/CE pauses. All transfers require CE and valid/ready at a rising edge; ready is suppressed during CE=0/reset/abort as applicable. cfg_fill is snapshotted on START. Frame error codes are80 invalid static profile,81 source marker mismatch,82 no active map,93 abort,94 internal state. Map codes are81 map_last mismatch,82 incomplete commit,93 map abort.

Synchronous active-low reset overrides CE, drops frames/map transactions and **invalidates both map banks**; reload/commit a map after reset. Abort immediately suppresses output and becomes terminal93 on an enabled edge; keep asserted through that edge. Replay abort invalidates all output from the frame, including previously sent pixels. A late abort does not alter held frame DONE. No dropped-input timeout is claimed; a source that stops early must abort/reset. The core is whole-frame buffered and serialized, not a camera-rate or one-pixel-per-clock throughput claim.

## Independent verification and OpenCV paths

run_tests.py uses an independent Python integer oracle: signed divmod, mathematical four-neighbor weights, per-tap constant border and final rounding, comparing every output data/valid/marker token exactly. Tests exercise8/10/12bits, both interpolation modes, differing source/destination geometry, nonlinear maps, full signed-coordinate extremes, phase ties, narrow frames and repeated frames. Three additional cases load maps generated by actual cv2.initUndistortRectifyMap using explicit synthetic intrinsic/distortion/rotation parameters; they demonstrate calibration-map consumption, **not an actual camera calibration measurement**. Host maps are quantized to the specified Q8 format before loading.

Installed OpenCV5.0.0 remap has materially different float-map and converted fixed-map paths. Tests call both actual APIs: remap(float maps,INTER_LINEAR,BORDER_CONSTANT), and convertMaps(...,CV_16SC2) followed by remap(fixed maps,...). Q8 mode is checked against the float path; Q5 mode against the fixed path. Observed matched-path error is0 in the recorded fixtures (allowed1 for rounding variants). Both cross-path errors are also reported, never hidden. Phase rounding can shift each axis by<=1/64 pixel; for bounded image/fill pixels the bilinear Lipschitz bound gives cross-path difference <=P/32+rounding, conservatively floor(P/32)+2. The stress evidence exposes cross-path differences up to127 at12bits while matched-path comparisons remain exact. This is expected numerical-model variation, not an excuse for a coordinate-phase bug.

Protocol tests exercise no-map START, incomplete commit, wrong map_last, concurrent inactive loading while the old map drives a complete frame, deferred commit across held frame DONE, old-map retention after load/abort errors, malformed source termination, frame abort in capture/held output, CE pauses, output stability and reset with CE=0 followed by map reload and healthy replay. Numeric tests cover maximum pixels/fill, maximum signed coordinates and Q5 tie/round carry boundaries.

## Reproduce and resource evidence

```powershell
python -B cores/system/common_scaffold/image/stereo_rectify/run_tests.py
python -B cores/system/common_scaffold/image/stereo_rectify/test_protocol.py
python -B cores/system/common_scaffold/image/stereo_rectify/test_numeric_limits.py
python -B cores/system/common_scaffold/image/stereo_rectify/synth.py
```

Synthesis profiles use16x12 geometry and count LUT/ALU/MUX plus4 LUT equivalents per RAM16SDP4:8bit/Q8=2779,10bit/Q5=2147,12bit/Q8=3552 LUT-class; all use0 DSP and12 SDPX9B. Synchronous source storage may map to LUTRAM, which is included. Larger geometry/profile budgets require their own synthesis. JSON evidence binds source SHA256. Temporary compile/synthesis directories are removed automatically; downloaded reference sources are hashed then cleaned. No JTAG, board, post-route timing or real-camera image-quality acceptance is claimed.

references.json records the actually retrieved OpenCV4.x imgwarp.cpp source hash and the areas inspected: canonical bilinear tables, convertMaps phase handling and per-tap BORDER_CONSTANT. Actual runtime evidence separately identifies installed OpenCV5.0.0 so older implementation details are not incorrectly asserted as universal. No third-party RTL/C code was copied.

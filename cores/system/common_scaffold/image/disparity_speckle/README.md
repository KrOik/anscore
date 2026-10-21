# Whole-frame disparity speckle removal

`disparity_speckle.sv` performs true four-neighbor connected-component filtering over a captured disparity frame. A valid pair of adjacent pixels is joined exactly when `abs(raw_d1-raw_d2)<=cfg_range`. Paths can therefore connect endpoints whose disparity difference exceeds cfg_range through a threshold chain. Diagonal-only contacts do not connect. This is not a local majority or median filter.

A component is removed when its pixel count is **less than or equal to cfg_max_size**, matching OpenCV filterSpeckles. Size0 removes nothing. Source-invalid pixels are excluded from graph traversal and cannot bridge components. The output always preserves the exact original signed disparity value, including removed/source-invalid points: `m_invalid = source_invalid OR removed`, and `m_removed` identifies only newly removed valid points. No sentinel disparity is substituted.

## Parameters, configuration and protocol

WIDTH/HEIGHT1..4096 and WIDTH*HEIGHT<=65536; DISP_BITS2..32, DISP_FRAC0..16. DISP_FRAC is the declared external raw-disparity scaling; no fractional precision is lost or converted in filtering. cfg_range is an unsigned DISP_BITS raw-unit distance, so for DISP_FRAC4 a range16 means one physical disparity unit. Signed differences use DISP_BITS+1 bits, avoiding overflow even between -2^31 and2^31-1. cfg_max_size uses SIZE_BITS>=clog2(N+1), with SIZE_BITS<=24. Values greater than N reject the start with done_error/error_code1.

`start_valid && start_ready` atomically snapshots cfg_range and cfg_max_size for the complete frame. Subsequent changes on config pins cannot change a running frame. Start/ready requires rst_n && ce; no configuration or start is accepted while busy.

Capture exactly WIDTH*HEIGHT tokens in raster order, each with s_disparity, s_invalid, s_valid/s_ready, s_sof/eol/last. Markers must identify the first pixel, each real end-of-row and the final pixel. Any malformed marker ends the frame immediately with done_error/error_code2, before any output is emitted. Acknowledge done then restart a complete frame. A queue overflow guard reports error3; this should be unreachable for valid operation because visited is marked when enqueued, so every valid pixel can enter the queue at most once. Error4 is an illegal-state recovery diagnostic.

The full filtered frame is emitted in original raster order with m_sof/eol/last. m_valid, disparity, status and markers remain stable until ce && m_ready. Done is held until ce && done_ready. Input/start ready are low with CE disabled; output/done valid remain asserted during CE pause. Reset is synchronous active-low, takes priority over CE, cancels partial capture/BFS/removal/output and returns to idle. No RAM reset is used: a fresh complete capture initializes visited and removed at every address before reuse. There is no timeout for missing input or downstream backpressure.

## Architecture and bounds

One signed disparity+invalid frame RAM, one visited bitmap, one removed bitmap, and one N-entry BFS address queue are used. Each logical RAM has exactly one write port and one registered read port, permitting actual BRAM mapping. Processing scans for unseen seeds, performs serialized BFS, and retains every component's queue entries. If the finished component is small enough, a second queue pass marks its pixels removed. The component cannot be truncated at a fixed local window or queue size smaller than N. Runtime/storage are O(N); four adjacency checks per visited point, bounded serial RAM accesses, and at most one removal write per valid pixel. Capture and output are separate full-frame phases, not live-video II1 processing.

Default32x16/D24 isolated Gowin synthesis:1207 conservative LUT-class (includes64 RAM16SDP4 counted as256 LUT equivalents),0DSP,1 DPX9B+1 SDPX9B; conservative physical memory accounting counts each mapped BRAM primitive as2 units of9Kb, total4. A larger64x32/D24 profile maps all logical stores into2 DPB+5 DPX9B, uses862 LUT-class/0DSP and conservative14 units of9Kb. A non-power-of-two31x17/D16 profile uses1642 LUT-class/0DSP,2 DPX9B and66 RAM16SDP4, conservative4 BRAM9 units. LUT totals include ALU/MUX/LUTRAM; raw primitive counts are retained. Legal larger configurations are not certified to fit without their own synthesis. No PNR, timing, board or full-resolution throughput claim is made.

## Verification and provenance

```
python -B cores/system/common_scaffold/image/disparity_speckle/run_tests.py
python -B cores/system/common_scaffold/image/disparity_speckle/test_protocol.py
python -B cores/system/common_scaffold/image/disparity_speckle/test_numeric_limits.py
python -B cores/system/common_scaffold/image/disparity_speckle/synth_check.py
python -B cores/system/common_scaffold/image/disparity_speckle/freeze.py
```

18 frames/1374 output pixels are checked against an independent Python deque-BFS integer graph oracle. Cases include1x1/thin dimensions, full-frame connected components both kept/removed (queue reaches N), threshold chains, exact component-size boundary, diagonal-only contact, random fragmented maps, source-invalid holes/all-invalid, signed negative/fractional disparities, deletion disabled, and full signed32 difference extremes. Every disparity, invalid/removed flag and raster marker is checked, with deterministic randomized CE/output stalls and config mutation during busy.

Actual cv2.filterSpeckles comparisons cover1358 pixels over16 of those frames. OpenCV CV16S uses newVal=-32768 as the invalid/replacement sentinel; the oracle converts source-invalid pixels to that sentinel, compares the complete sentinel mask, and checks every surviving disparity. This core instead keeps original values and exposes separate flags. Two signed32-extreme frames fall outside unambiguous CV16S representation and are checked only with the exact integer oracle; they are not falsely claimed OpenCV comparisons. OpenCV/newVal collision with a valid -32768 is likewise outside this external check, while the RTL supports that valid raw value through its separate invalid bit.

Protocol tests cover one rejected size config,3 marker errors,4 CE-disabled resets during capture/BFS/component removal/output, and5 complete back-to-back recovery frames with different size policies.11 invalid parameter sets are rejected. Evidence JSONs bind current RTL SHA256; synthesis runs `synth_gowin -nodsp` and `check -assert`.

OpenCV source reference and inspected filterSpeckles implementation excerpt are recorded in references.json; no reference code was copied. Simulations, Yosys outputs and downloaded reference files use TemporaryDirectory and are cleaned automatically. Only small source/evidence files remain.

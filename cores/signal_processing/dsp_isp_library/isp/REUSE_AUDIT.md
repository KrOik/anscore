# ISP reuse audit — 2026-09-25

Scope: all nineteen ISP requirements in root goal.md. Read-only inspection of
imgwin, wave2 and CNN candidates; existing files/golden values untouched.
New files in this directory are models/specification only. Historical selftest
board results do not prove the new Stream, 10-bit, configuration or external
input contracts. No new synthesis or board operation was performed.

The root goal's synchronous reset and Stream specification governs new cores;
the older SOP's asynchronous reset/clk_en convention applies to legacy cores.
Do not silently rewrite accepted legacy contracts. imgwin `win3x3_gen` uses
two DPX9B line buffers with registered reads, row-marker beats before pixels,
8-bit samples and replicated edges. Its package documents a 16x16 formula
image digest BD71944D and historical board UART file; this is useful foundation,
not ready/valid support. Wave2 full-frame readers provide a second reuse path.
Adapters need complete halt control and SOF/EOL conversion, plus RAM collision,
first/last-row, minimum-size, bubbles and reset tests. 5x5 requires four rows.

Paths below are relative to `projects/`; W means `wave2_ip_20k/src/`, I means
`imgwin_20k/src/`, C means `cnn_systolic_20k/src/`. “Not found” is bounded to
these inspected project candidates, not a proof of repository-wide absence.

| Goal | Existing candidate / observed contract | Gap to requested delivery |
|---|---|---|
| 1 CSC | W/isp_csc.v, isp_rgb2gray.v; 8-bit BT601 Full Q8 shift-add | BT709, Limited, 10-bit, round-once saturation and atomic Stream config; new model here |
| 2 convolution | I/gaussian3x3.v; C/conv_layer.v CNN path | arbitrary signed 3x3/5x5 image kernels, border selection, scale, continuous Stream; CNN behavior cannot stand in for generic convolution |
| 3 median | I/median3x3.v; 21 compare-swaps, ~9 comparator levels | 10-bit, 5x5, elastic pipeline, explicit equal-value semantics and timing |
| 4 gradients | I/sobel_edge.v; saturated L1; W/canny_grad.v | Scharr, signed Gx/Gy public outputs, exact/approximate direction and magnitude contracts |
| 5 morphology | I/morph3x3.v; nonzero binary 3x3 square erode/dilate | grayscale, programmable elements, open/close composition, boundary/config and 10-bit |
| 6 ROI/scale | W/img_crop.v; W/img_scaler.v bilinear Q8 coords, 8 beats/output, <=1024 input pixels, power-of-two dimensions | nearest mode, center convention options, valid dimensions, atomic config, ready and continuous frames |
| 7 Bayer | W/isp_demosaic.v RGGB bilinear, truncating averages | other three patterns, ROI origin phase, 10-bit and qualified borders |
| 8 basic ISP | W/isp_awb.v next-frame gray-world (power-of-two <=1024 pixels); isp_dpc.v med8 threshold; isp_gamma.v three shared-curve RAMs | BLC, explicit external gains mode, bad-cluster limits, atomic LUT changes, Stream and 10-bit |
| 9 CCA | W/ccl_bbox.v true two-pass union-find, 4-connectivity, 63 labels with overflow flag, area/bbox | 8-connectivity, centroid sums/division, continuous frame scheduling, bounded general config, ready |
| 10 local statistics | W/img_integral.v exact 18-bit rows at 32x32; larger sums wrap | wider general sums, squares, mean/variance, adaptive threshold and area/border contract |
| 11 equalization | W/img_histogram.v RAM hazard forwarding; hist_clahe.v 32x32, 16-bin prototype | full equalization/CDF constant-image policy; proper clipped-mass redistribution; 256/1024 bins; configurable tiling, framing, buffer/throughput |
| 12 AE/AWB/AF | W/isp_awb.v channel sums and next-frame gains; gradient candidates | independent tiled statistics output, overexposure, AF energy, exposure advice tests; no camera closed-loop claim |
| 13 LSC | no direct candidate found | channel grid import/generation, bilinear gain, clamp, Bayer preservation |
| 14 CCM/tone | W/isp_csc.v arithmetic; isp_gamma.v LUT | signed configurable matrix/offset, domain definition, monotonic curves and update boundaries |
| 15 chroma/packing | CSC 4:4:4 channel layout only | filtered 422/420 conversion, cositing, odd sizes, planar/interleaved packing and rate contracts |
| 16 Canny | W/canny_grad/nms/dth/hyst.v; hyst single local propagation | exact full-frame hysteresis connectivity; integrated Gaussian chain; local mode separately named |
| 17 temporal | W/frame_diff.v previous-frame RAM; bg_model.v running mean | general continuous frame lifecycle, ready and background scene-change recovery; current BGS emits final frame mask/background only |
| 18 bilateral | no direct candidate found | 3x3 spatial/range LUTs, normalized weighted sum, zero protection and error tests |
| 19 remapping | W/img_scaler.v small frame-buffer bilinear sampler | flip/rotate/affine/projective/distortion coordinates, division accuracy, general random access and storage bandwidth |

Evidence reviewed: wave2 `ip/isp_csc/ip_manifest.json` exposes a *selftest*
start/done/pass/digest wrapper (CE41D92D), not user pixel pins. Its manifest
reports historical grouped noalu board PASS. `doc/VALIDATION_LOG.md` lists
the original ISP/Canny/integral/scaler/CLAHE/CCA golden digests and independent
golden scripts. Core source comments and logic were inspected for CSC and the
bounded/approximate behavior above. imgwin `ip/win3x3_gen/README.md` describes
the real pixel interface and DPX9B behavioral simulation dependency. Existing
CNN status in `docs/IP_OPTIMIZATION_STATUS.md` distinguishes production spatial
sum repair from isolated input/activation candidates. The latest inspected
`artifacts/board_recheck_20260925_020111/SESSION.md` validates only SSUM UART
transport, not this new ISP library.

First implementation gate: shared Stream/window contract tests must pass,
then CSC elastic RTL against independently generated vectors; 3x3 algorithms
follow the tested shared window. Bounded full-frame candidates remain reusable
but require explicit scheduling, not an unconditional II=1 promise. No current
entry meets the full new per-IP acceptance gate.

Commands/results: `python cores/signal_processing/dsp_isp_library/isp/test_csc_model.py`
PASS, 24 mode combinations, 114360 vectors, maximum float-reference error
0.5161290322581635 code; detailed per-mode results in csc_model_results.json.
This qualifies only model/specification. LUT/FF/DSP/BRAM impact: not measured.

# 48 个公开入口板测覆盖审计

审计时间：2026-10-18T13:52:05.418454+00:00。当前 **0 / 48 公开入口具备完整板测验收证据，48 项均待验收**。这是历史证据审计，没有新增烧录。

验收要求：实际例化公开 `cip_*` 入口、当前源文件哈希关联、JTAG SRAM 加载成功、UART 功能检查一致。历史 `img_*` 隔离核通过仅作为底层参考，不能计作公开入口通过。

已检查历史板目录及 build 候选一级的 280 个 Verilog 源文件；未发现这 48 个公开入口实例。此检索没有声称覆盖所有深层历史快照或其他项目。manifest 本身仍记录入口 board=not_run。

## 待验收入口

| 入口 | 公开入口验收 | 已有底层参考组 |
| --- | --- | --- |
| `cip_fir_stream` | 待验收 | 无已核对成功证据 |
| `cip_iir_biquad_stream` | 待验收 | 无已核对成功证据 |
| `cip_fft_stream` | 待验收 | 无已核对成功证据 |
| `cip_cic_decimator` | 待验收 | 无已核对成功证据 |
| `cip_resampler_stream` | 待验收 | 无已核对成功证据 |
| `cip_cordic_stream` | 待验收 | 无已核对成功证据 |
| `cip_image_dehaze` | 待验收 | dehaze_dcp, guided_refine |
| `cip_image_dark_channel` | 待验收 | dehaze_dcp |
| `cip_image_transmission` | 待验收 | dehaze_dcp |
| `cip_image_recover` | 待验收 | dehaze_dcp |
| `cip_image_scaler` | 待验收 | geometry |
| `cip_image_rotate` | 待验收 | geometry |
| `cip_image_downsample` | 待验收 | 无已核对成功证据 |
| `cip_image_upsample` | 待验收 | 无已核对成功证据 |
| `cip_image_super_resolution` | 待验收 | 无已核对成功证据 |
| `cip_image_window` | 待验收 | window_filter8 |
| `cip_image_color_convert` | 待验收 | isp_pointwise |
| `cip_image_framebuffer` | 待验收 | geometry |
| `cip_image_bayer_demosaic` | 待验收 | bayer |
| `cip_image_gamma` | 待验收 | ccm_gamma |
| `cip_image_awb` | 待验收 | awb48, awb_solver48 |
| `cip_image_ccm` | 待验收 | ccm_gamma |
| `cip_image_histogram` | 待验收 | he |
| `cip_image_he` | 待验收 | he |
| `cip_image_clahe` | 待验收 | clahe |
| `cip_image_brightness_contrast` | 待验收 | isp_pointwise |
| `cip_image_mean_filter` | 待验收 | window_filter8 |
| `cip_image_gaussian_filter` | 待验收 | window_filter8 |
| `cip_image_median_filter` | 待验收 | window_filter8 |
| `cip_image_bilateral_filter` | 待验收 | bilateral |
| `cip_image_guided_filter` | 待验收 | guided_refine |
| `cip_image_temporal_denoise` | 待验收 | temporal |
| `cip_image_nlm_denoise` | 待验收 | 无已核对成功证据 |
| `cip_image_sobel` | 待验收 | window_filter8 |
| `cip_image_prewitt` | 待验收 | window_filter8 |
| `cip_image_canny` | 待验收 | canny |
| `cip_image_laplacian` | 待验收 | 无已核对成功证据 |
| `cip_image_threshold` | 待验收 | window_filter8 |
| `cip_image_morphology` | 待验收 | window_filter8 |
| `cip_image_affine` | 待验收 | geometry |
| `cip_image_mirror_flip` | 待验收 | geometry |
| `cip_image_invert` | 待验收 | 无已核对成功证据 |
| `cip_image_perspective` | 待验收 | geometry |
| `cip_image_osd` | 待验收 | multiframe |
| `cip_image_frame_difference` | 待验收 | multiframe |
| `cip_image_background_model` | 待验收 | multiframe |
| `cip_image_stitch` | 待验收 | stitch |
| `cip_image_fusion` | 待验收 | multiframe |

## 底层成功证据的限定范围

以下各组的原始 UART/JTAG 记录、摘要哈希、bitstream 哈希和源／build 链接保存在 coverage.json。它们均不提升公开入口状态。

- **ccm_gamma**：PASS；373 bounded RGB888 CCM/Gamma vectors with configuration transitions, periodic CE pauses and sink backpressure; real 50 MHz clock; four-stage CCM and aligned Gamma path. Not full-video/all-parameter validation. 摘要：`board/tang25k/build/image_ccm_gamma_selftest_25k_20261017_v60_ccmpipe/board_validation_summary.json`。
- **awb48**：PASS；{"function": "Default SUM_WIDTH48 RGB stats -> flush -> hardware gray-world autogain -> UART gains/digest", "sum_width": 48, "input_rgb_pixels": 4, "input_hex": ["102030", "203040", "304050", "405060"], "expected_gains_q8": [358, 256, 199], "expected_digest": "000001C1", "uart_bytes": 47, "simulation_uart_quiet_bits": 12, "clk_en": "constant1; every physical50MHz edge", "solver": "16bit/nibble-prefix borrowed iteration; exact floor and original latency", "limitations": "Real board only four ordinary pixels; high48 sums/invalid metadata/CE pauses covered in simulation and separate v91 ROM candidate pending; not full automatic pixel-correction pipeline or large-frame validation"} 摘要：`board/tang25k/build/image_awb48_selftest_25k_20261017_v95_borrowprefix/board_validation_summary.json`。
- **awb_solver48**：PASS；{"function": "Hardware ROM -> real default48 AWB autogain -> per-gain/frame/error checker -> finite UART", "sum_width": 48, "solver_vectors": 17, "board_stimulus": "17-entry 329-bit synthesized ROM; no testbench preload", "solver_clk_en": "constant 1", "uart_bytes": 25, "checks": ["all RGB gains", "frame_id", "error flags", "tiny totals0/1/2/3", "high48 sums", "zero-channel", "zero-count", "stats-overflow metadata", "min/max-order"], "simulation_only": "five stats-preload tests; CE/backpressure; injected checker fault; reset deterministic replay; 12-bit UART quiet tail", "limitations": "This board image instantiates solver only; high48 stats accumulation and complete real-camera/full-frame AWB feedback not board-signed-off here"} 摘要：`board/tang25k/build/image_awb48_vectors_selftest_25k_20261017_v91/board_validation_summary.json`。
- **bayer**：PASS；{"function": "RAW streaming -> synchronous two-line 3x3 valid-crop window -> bilinear Bayer RGB888", "raw_bits": [8, 10, 12], "patterns": ["RGGB", "GRBG", "GBRG", "BGGR"], "frames_per_lane": 13, "aggregate_input_pixels": 1941, "aggregate_rgb_outputs": 1035, "explicit_error_responses": 9, "maximum_frame": "11x8", "ce_schedule": "13 enabled edges per 16 clocks; phases 5/6/7 disabled", "uart_bytes": 52, "simulation_uart_quiet_bits": 12, "limitations": "Finite small frames only; not default MAX_WIDTH1920 or continuous video signoff"} 摘要：`board/tang25k/build/image_bayer_frame_selftest_25k_20261017_v84_porreg/board_validation_summary.json`。
- **he**：PASS；{"function": "Complete GRAY8 HE capture -> histogram/CDFmin LUT -> exact floor normalization -> replay", "frame_width": 16, "frame_height": 16, "count_width": 16, "commands": 9, "successful_commands": 7, "explicit_frame_errors": 2, "input_pixels": 2304, "output_pixels": 1792, "constant_frame": "preserve original gray value", "ce_schedule": "13 enabled per16 clocks; disabled5/6/7", "uart_bytes": 52, "simulation_uart_quiet_bits": 12, "limitations": "Finite16x16 frames; miter checks other parameters but physical board signoff does not extend to them or sustained video", "engine_change": "Three modulo-equivalent branch predicates only; divider data/state/latency unchanged", "sink_ready_schedule": "disabled phases3/4 to exercise output valid across CE phases5/6/7", "production_status_at_qualification": "Five-stage interpolator matches production; predicate engine isolated pending board result"} 摘要：`board/tang25k/build/image_he16_selftest_25k_20261017_v90_predicate/board_validation_summary.json`。
- **clahe**：PASS；{"function": "Complete GRAY8 CLAHE capture -> per-tile histogram/clip/redistribution/CDF LUT -> full precision interpolation -> replay", "frame_width": 64, "frame_height": 32, "tile_width": 32, "tile_height": 16, "tiles": [2, 2], "count_width": 16, "fraction_bits": 6, "commands": 7, "successful_commands": 4, "explicit_parameter_errors": 1, "explicit_frame_errors": 2, "input_pixels": 12288, "output_pixels": 8192, "clip_limits": [2, 3, 4], "ce_schedule": "13 enabled per16 clocks; disabled5/6/7", "uart_bytes": 52, "simulation_uart_quiet_bits": 12, "interpolation_latency_enabled_edges": 5, "interpolation_ii_enabled_edges": 1, "limitations": "Finite configured frames; not OpenCV bit-exact CLAHE or sustained video/other dimensions signoff", "integrated_production_rtl": "Current v90 predicate engine and single-file five-stage interpolator; all ten RTL byte-identical to current production"} 摘要：`board/tang25k/build/image_clahe4_selftest_25k_20261017_v94_predicate/board_validation_summary.json`。
- **canny**：PASS；Isolated complete bounded-frame GRAY8 Canny self-test, MAX8x8; Gaussian/Sobel L1/Q8 four-direction NMS/dual thresholds/repeated 8-connected hysteresis, including nine-hop weak chain. Ten commands, 272 real inputs/outputs, four expected command errors; CE13/16, output/response backpressure and config perturbation. Actual50MHz, original fixed272-pixel golden digest7C514D90 and 46-byte UART. Four extra registered Sobel enabled stages per pixel; not continuous video, larger-frame or arbitrary-parameter signoff. 摘要：`board/tang25k/build/image_canny_frame_selftest_25k_20261017_v100_gradpipe/board_validation_summary.json`。
- **dehaze_dcp**：PASS；Isolated complete RGB888 DCP bounded-frame self-test, MAX3x3, MAX_RADIUS1: real RGB input, dark channel, same-frame auto/manual airlight, channel normalization, Q15 transmission, real optional guided refinement, signed saturated recovery and replay. Ten commands, 41 real inputs/outputs, four expected errors; two actual guided frames, CE1/4, backpressure and command snapshot checks. Actual50MHz, unchanged digest5512B18B and 51 UART bytes. No larger-frame, continuous-video or FPS signoff. 摘要：`board/tang25k/build/image_dehaze_frame_selftest_25k_20261017_v96d_dcp_full/board_validation_summary.json`。
- **guided_refine**：PASS；Bounded guided-refine stage, not complete dehaze pipeline: four fixed grayscale-guide/Q1.15 transmission frames, 400 output pixels, radius/epsilon cases, edge replication, synchronous coefficient RAM, CE4 and output/response backpressure; exact Python pixel checks and 160 UART bytes. No continuous-video, arbitrary frame-size or default-parameter signoff. 摘要：`board/tang25k/build/dehaze_guided_refine_selftest_25k_20261017_v73_allmul/board_validation_summary.json`。
- **window_filter8**：PASS；Bounded end-to-end frame/window plus eight filters: five GRAY8 frames, 206 pixels, 102 valid-crop windows, max 9x8; all nine taps, coordinates/markers and independent sink backpressure checked against Python fixtures. Real 50 MHz; CE is enabled for 13 of each 16 clocks (disabled phases 5,6,7). No padding or full-video throughput signoff. 摘要：`board/tang25k/build/image_window_filter8_selftest_25k_20261017_v70_meanrom/board_validation_summary.json`。
- **geometry**：PASS；Isolated grayscale8 frame geometry, MAX_WIDTH=4, MAX_HEIGHT=3. 14 commands, 168 inputs, 182 outputs and 2 expected error responses. Nearest/bilinear geometry with scale, rotation, mirror, affine and external perspective mapping; CE/backpressure/reset/error recovery. Actual 50MHz/CE13/16, no timing exception; no larger-frame timing or continuous-video throughput signoff. 摘要：`board/tang25k/build/image_geometry_frame_selftest_25k_20261017_v89m/board_validation_summary.json`。
- **multiframe**：PASS；Isolated MAX4x3 RGB888 multiframe application self-test: real dual-frame BRAM store, OSD key/alpha, absolute difference, persistent Q8.8 EWMA background update and weighted fusion. Thirty-eight commands, 88 main and 61 auxiliary inputs, 168 outputs, 60 actual background writebacks, 11 expected errors. Actual50MHz, CE13of16, original EDA58BD3 and 58 exact UART bytes. Includes read/copy wait states and three-stage elastic OSD/fusion arithmetic. No automatic stitching, larger frame or continuous-video throughput signoff. 摘要：`board/tang25k/build/image_multiframe_selftest_25k_20261017_v101b_pipeline/board_validation_summary.json`。
- **stitch**：PASS；Isolated RGB888 4x3 registration/stitch chain, shift1, two ROI samples and nine ordered trials; 6x5 output canvas. 32 commands, 62 main/75 auxiliary inputs, 300 outputs and 14 expected errors. Luma SAD, first-min ties, confidence rejection, weighted composition, manual homography, framing errors and recovery. Actual 50MHz/CE1/4; no larger-frame timing or continuous-video throughput signoff. 摘要：`board/tang25k/build/image_autostitch_frame_selftest_25k_20261017_v105d_addrpipe/board_validation_summary.json`。
- **bilateral**：PASS；Isolated GRAY8 bilateral 3x3 external-window kernel. Thirty-eight sigma configurations, 35 nine-tap windows and three expected errors; seven sigma pairs include Q8.8 values1 and65535. Shared iterative divider, registered weighted product and exact partial-product sigma squares; original766615F3 and43 exact UART bytes. Actual50MHz, CE13of16; no frame-window generation or continuous-video signoff. 摘要：`board/tang25k/build/image_bilateral_selftest_25k_20261017_v104c_sigmapipes/board_validation_summary.json`。
- **temporal**：PASS；GRAY8 MAX4x3 isolated temporal-denoise self-test. Two real DUTs cover internal synchronous filtered-output history and external paired history. Thirty-two commands,207 main inputs/outputs,79 external-history pairs, 11 expected errors; original543453C2 and57 exact UART bytes. Motion-gated half-up Q8 blend, history invalidation and registered products. Actual50MHz,CE13of16; not default64x64 timing or video signoff. 摘要：`board/tang25k/build/image_temporal_frame_selftest_25k_20261017_v106/board_validation_summary.json`。
- **isp_pointwise**：PASS_BOUNDED_SCOPE；188 output/marker checks and exact 210 bytes per run; actual 50MHz with CE4; not all ISP/full frontend qualification 摘要：`board/tang25k/build/image_isp_common_selftest_25k_20261017_v54_watchdog/board_validation_summary.json`。

## 保留失败及未签核记录

原有日志没有修改或删除。`evidence/20261017_validation_status.md` 记载 v53 板测失败、v63 多余 NUL 导致严格 UART 失败、v102k setup 失败及后续 HOLD_UNPROVEN 等。coverage.json 链接相关 build 摘要；成功的后继候选不能抹去失败历史。

每个入口仍需要独立的公开接口板测工程，冻结准确 RTL／oracle／向量／bitstream 哈希，再逐份加载 SRAM 和核对 UART。运行时模式、错误、配置、CE／背压及复位的验收范围应逐项记录；有限画布或固定参数通过不能扩展成所有参数通过。

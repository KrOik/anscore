# JTAG recovery functional acceptance retest

## Latest completed retest: 2026-10-19 22:49–23:04

**48/48 functional board PASS**, 144 actual SRAM loads and exact UART matches. Independent audit PASS; all 202 production source hashes unchanged.

- [Run](restored_jtag_retest_20261019_224903.json)
- [Independent audit](audit_restored_jtag_retest_20261019_224903_20261019_230451_2b462350.md)
- [Storage check](cleanup_restored_jtag_retest_20261019_224903.json): zero new bitstreams remain; all 47 preexisting bitstreams retained, including historical alternate candidates.

Functional fixture scope only; hold timing remains unproven. No RTL changes or synthesis in this retest.

## Latest completed retest: 2026-10-19 21:00–21:14

**48/48 functional board PASS**, 144 actual SRAM loads and exact UART matches. Independent audit PASS; all 202 production hashes unchanged.

- [Run](restored_jtag_retest_20261019_210051.json)
- [Independent audit and per-module evidence](audit_restored_jtag_retest_20261019_210051_20261019_211426_3319a573.md)
- [Cleanup check](cleanup_restored_jtag_retest_20261019_210051.json): zero newly generated bitstreams remaining; 31 baseline bitstreams preserved.

Local Tang Primer 25K, COM44 / 115200. No RTL changes or new synthesis; existing frozen route, resource and setup gates rechecked. Scope: bounded functional fixtures. Hold timing, full-resolution video, image quality and extension-library board signoff remain unproven.


Latest completed local retest (2026-10-19 17:19–17:33): **48/48 PASS**, 144 actual SRAM loads and exact UART matches. Independent audit PASS; all 202 production source hashes unchanged.

- [Latest run](restored_jtag_retest_20261019_171941.json)
- [Latest independent audit and per-module evidence](audit_restored_jtag_retest_20261019_171941_20261019_173332_7368f013.md)
- [Cleanup check](cleanup_restored_jtag_retest_20261019_171941.json)

Local Tang Primer 25K, COM44 / 115200. No RTL changes or new synthesis; frozen resource/route gates rechecked. Newly generated temporary bitstreams removed; preexisting artifacts and logs preserved. Scope: bounded functional fixtures. Hold timing, full-resolution video and image-quality signoff remain unproven. New extension cores are outside this 48-entry board round.

## Earlier completed rounds

Latest completed local retest (2026-10-19 16:22–16:35): **48/48 PASS**, 144 actual SRAM loads and exact UART matches. Independent audit PASS; all 202 production source hashes unchanged.

- [Latest run](restored_jtag_retest_20261019_162224.json)
- [Latest independent audit and per-module evidence](audit_restored_jtag_retest_20261019_162224_20261019_163558_54d1f1f8.md)

This round is the authoritative latest completed acceptance. Local Tang Primer 25K, COM44 / 115200. Existing frozen resource/route gates were rechecked; no RTL changes or new synthesis. Newly generated temporary bitstreams were removed after successful provenance checks. Scope remains bounded functional fixtures; hold timing and full-resolution image-quality signoff remain unproven. New extension cores are outside this 48-entry round.

The redundant 16:08 round was interrupted after three entries and is **not an
acceptance result**. Its raw `RUNNING` record is retained unchanged; no board
process remains active. See [termination record](interrupted_retest_20261019_160814.json).
The completed 15:15 round below is retained as historical acceptance.

Latest local retest (2026-10-19 15:15–15:29): **48/48 PASS**, 144 actual SRAM loads and exact UART matches. Independent audit PASS; all 202 production source hashes unchanged.

- [Latest run](restored_jtag_retest_20261019_151537.json)
- [Latest independent audit and per-module evidence](audit_restored_jtag_retest_20261019_151537_20261019_152908_458ab418.md)

Local Tang Primer 25K, COM44 / 115200. No RTL changes or new synthesis; existing frozen route/resource gates were rechecked. Newly generated temporary bitstreams were removed after successful provenance checks; baseline artifacts and logs retained. Scope: frozen bounded functional fixtures. Hold timing and full-resolution image-quality signoff remain unproven. New extension cores are outside this 48-entry acceptance round. Earlier rounds below are retained.

Latest local retest (2026-10-19 13:24–13:39): **48/48 PASS**, 144 actual SRAM loads and exact UART matches. Independent audit PASS; all 202 production source hashes unchanged.

- [Latest run](restored_jtag_retest_20261019_132433.json)
- [Latest independent audit and per-module evidence](audit_restored_jtag_retest_20261019_132433_20261019_133958_04040da1.md)

Command: `python -B cores/system/common_scaffold/board/tang25k/acceptance48/retest_restored_jtag.py`
Audit: `python -B cores/system/common_scaffold/board/tang25k/acceptance48/audit_retest.py cores/system/common_scaffold/board/tang25k/acceptance48/restored_jtag_retest_20261019_132433.json`
No RTL changes or new synthesis. Frozen bounded functional fixtures only; hold timing remains unproven. Earlier runs below are retained.


Latest local retest (2026-10-19 12:20–12:35): **48/48 PASS**, 144 actual SRAM loads and exact UART matches; independent audit PASS, all 202 production source hashes unchanged.

- [Latest run](restored_jtag_retest_20261019_122044.json)
- [Latest independent audit and per-module evidence](audit_restored_jtag_retest_20261019_122044_20261019_123522_e9e8e21c.md)

No RTL changes or new synthesis in this retest. New temporary bitstreams were removed after successful checks; existing artifacts retained. Scope remains frozen bounded functional fixtures, with hold timing unproven. The table below preserves the earlier run.

2026-10-19: 48/48 entries PASS; 144 actual SRAM loads and exact UART matches.

Device: local Tang Primer 25K / GW5A-25, COM44 / 115200.
Scope: frozen bounded functional fixtures. Hold timing remains UNPROVEN; this is not full timing or image-quality signoff.

| Module | SRAM/UART repeats | Evidence |
|---|---:|---|
| cip_fir_stream | 3 | [record](rtl_dsp/fir_v5_20261018_220000/functional_board_frozen_seed3_20261019_023049_793120.json) |
| cip_iir_biquad_stream | 3 | [record](rtl_dsp/iir_optimized/case_v1/functional_board_accept_20261018_221914_20261019_023111_086099.json) |
| cip_fft_stream | 3 | [record](rtl_dsp/fft_optimized/case_v3/functional_board_frozen_seed3_20261019_023132_120554.json) |
| cip_cic_decimator | 3 | [record](rtl_dsp/cic_optimized/case_v3/functional_board_frozen_seed3_20261019_023153_417121.json) |
| cip_resampler_stream | 3 | [record](rtl_dsp/resampler_optimized/case_v3/functional_board_accept_20261018_224626_20261019_023214_652505.json) |
| cip_cordic_stream | 3 | [record](rtl_dsp/cordic_v5_20261018_220000/functional_board_frozen_seed3_20261019_023235_731916.json) |
| cip_image_dehaze | 3 | [record](scalar_dehaze_optimized/dehaze_production_v3/functional_board_accept_20261019_004914_20261019_023309_301911.json) |
| cip_image_dark_channel | 3 | [record](scalar_dehaze_optimized/dark_channel_production_v2/functional_board_accept_20261019_004955_20261019_023341_373463.json) |
| cip_image_transmission | 3 | [record](scalar_dehaze_optimized/transmission_production_v3/functional_board_accept_20261019_005059_20261019_023412_861893.json) |
| cip_image_recover | 3 | [record](scalar_dehaze_optimized/recover_v3/functional_board_accept_20261018_230429_20261019_023434_438637.json) |
| cip_image_scaler | 3 | [record](geo_optimized/scaler_production_v10/functional_board_accept_20261019_011217_20261019_023507_341316.json) |
| cip_image_rotate | 3 | [record](geo_mapping_optimized/rotate_current_v8/functional_board_rotate_current_20261019_20261019_023541_100858.json) |
| cip_image_downsample | 3 | [record](geo_optimized/downsample_production_v5/functional_board_accept_20261019_011227_20261019_023613_075085.json) |
| cip_image_upsample | 3 | [record](geo_optimized/upsample_production_v6/functional_board_accept_20261019_011157_20261019_023645_669383.json) |
| cip_image_super_resolution | 3 | [record](scalar_dehaze_optimized/super_resolution_rtl_v7/functional_board_frozen_seed3_20261019_023718_534588.json) |
| cip_image_window | 3 | [record](window_frame_optimized/window_v2/functional_board_frozen_seed3_20261019_023739_973192.json) |
| cip_image_color_convert | 3 | [record](cases/color_optimized_v2/functional_board_color_rom_20261018_20261019_023801_263477.json) |
| cip_image_framebuffer | 3 | [record](scalar_dehaze_optimized/framebuffer_counts_v9/functional_board_accept_20261018_235527_20261019_023822_952004.json) |
| cip_image_bayer_demosaic | 3 | [record](cases/bayer_demosaic_v1/functional_board_accept_20261018_224900_20261019_023844_630774.json) |
| cip_image_gamma | 3 | [record](cases/gamma_v3/functional_board_accept_20261018_220351_20261019_023905_858996.json) |
| cip_image_awb | 3 | [record](scalar_dehaze_optimized/awb_counts_v4/functional_board_accept_20261018_233640_20261019_023927_490503.json) |
| cip_image_ccm | 3 | [record](scalar_dehaze_optimized/ccm_harness_v3/functional_board_accept_20261018_231347_20261019_023948_755351.json) |
| cip_image_histogram | 3 | [record](cases/histogram_production_v2/functional_board_hist_production_20261018_20261019_024010_158352.json) |
| cip_image_he | 3 | [record](cases/he_mapping_v2/functional_board_he_width_20261018_20261019_024031_487751.json) |
| cip_image_clahe | 3 | [record](clahe_optimized/case_v8/functional_board_clahe_bounded_count_v8_20261019_024052_784708.json) |
| cip_image_brightness_contrast | 3 | [record](cases/brightness_v5/functional_board_frozen_seed3_20261019_024114_478790.json) |
| cip_image_mean_filter | 3 | [record](scalar_dehaze_optimized/mean_filter_production_v6/functional_board_accept_20261019_003750_20261019_024145_673980.json) |
| cip_image_gaussian_filter | 3 | [record](scalar_dehaze_optimized/gaussian_filter_production_v6/functional_board_accept_20261019_003838_20261019_024217_149413.json) |
| cip_image_median_filter | 3 | [record](cases/median_pipeline_v6/functional_board_median_pipeline5_20261018_20261019_024238_464070.json) |
| cip_image_bilateral_filter | 3 | [record](scalar_dehaze_optimized/bilateral_rom_v9/functional_board_accept_20261019_002227_20261019_024259_809991.json) |
| cip_image_guided_filter | 3 | [record](scalar_dehaze_optimized/guided_harness_v2/functional_board_guided_seed7_20261019_20261019_024321_287291.json) |
| cip_image_temporal_denoise | 3 | [record](scalar_dehaze_optimized/temporal_v2/functional_board_accept_20261018_230511_20261019_024343_169236.json) |
| cip_image_nlm_denoise | 3 | [record](nlm_optimized/case_v10/functional_board_nlm_bounded_control_v10_20261019_024415_056173.json) |
| cip_image_sobel | 3 | [record](scalar_dehaze_optimized/sobel_production_v6/functional_board_accept_20261019_003923_20261019_024446_703258.json) |
| cip_image_prewitt | 3 | [record](scalar_dehaze_optimized/prewitt_production_v6/functional_board_accept_20261019_004019_20261019_024518_618133.json) |
| cip_image_canny | 3 | [record](cases/canny_v1/functional_board_accept_20261018_231844_20261019_024540_006687.json) |
| cip_image_laplacian | 3 | [record](scalar_dehaze_optimized/laplacian_production_v6/functional_board_accept_20261019_004127_20261019_024611_259879.json) |
| cip_image_threshold | 3 | [record](cases/threshold_optimized_v10/functional_board_threshold_counts_seed5_20261018_20261019_024632_661964.json) |
| cip_image_morphology | 3 | [record](cases/morphology_mapping_v3/functional_board_morph_addr_20261018_20261019_024654_400181.json) |
| cip_image_affine | 3 | [record](geo_mapping_optimized/affine_current_v5/functional_board_affine_current_20261019_20261019_024727_498183.json) |
| cip_image_mirror_flip | 3 | [record](cases/mirror_v1/functional_board_mirror_20261018_no_lutram_20261019_024749_284694.json) |
| cip_image_invert | 3 | [record](cases/invert_v1/functional_board_accept_20261018_220351_20261019_024810_491850.json) |
| cip_image_perspective | 3 | [record](geo_mapping_optimized/perspective_current_v5/functional_board_perspective_current_20261019_20261019_024843_718836.json) |
| cip_image_osd | 3 | [record](scalar_dehaze_optimized/osd_harness_v2/functional_board_accept_20261018_231023_20261019_024905_274328.json) |
| cip_image_frame_difference | 3 | [record](window_frame_optimized/frame_difference_v5/functional_board_frozen_seed3_20261019_024926_943548.json) |
| cip_image_background_model | 3 | [record](scalar_dehaze_optimized/background_model_pipeline_v4/functional_board_accept_20261018_234303_20261019_024948_523202.json) |
| cip_image_stitch | 3 | [record](scalar_dehaze_optimized/stitch_production_v6/functional_board_accept_20261019_011832_20261019_025020_955788.json) |
| cip_image_fusion | 3 | [record](cases/fusion_counts_v7/functional_board_fusion_counts_20261018_20261019_025042_842802.json) |

All 202 production snapshot files unchanged. Newly generated temporary bitstreams removed by the runner after successful provenance checks; pre-existing baseline artifacts and logs retained.
Command: `python -B cores/system/common_scaffold/board/tang25k/acceptance48/retest_restored_jtag.py`
No RTL changes or new synthesis in this retest; existing frozen route/resource gates were rechecked before programming.

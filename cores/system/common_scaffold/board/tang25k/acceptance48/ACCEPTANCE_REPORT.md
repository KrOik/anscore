# 48 个公共 IP 入口功能验收记录

2026-10-19T01:30:14.201387+08:00

48/48 个当前源码版本均有至少三次实际 JTAG SRAM 烧录及精确 UART 输出一致性记录。
硬件：本机 Tang Primer 25K / GW5A-25，UART COM44 / 115200，50 MHz。
范围：本批 48 个公共入口的有界参数、数值夹具、流控和异常测试；不代表原有 300 余核全部重新验证。
所有结果仍为 FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN；保持时间未签核，不能作为完整时序签核。
图像效果、预训练超分模型质量和大分辨率连续视频性能不在本次夹具验收范围。

| 公开入口 | LUT4 | MULT12 | 最低报告频率 MHz | SRAM/UART 次数 | 当前源码板测证据 |
|---|---:|---:|---:|---:|---|
| cip_fir_stream | 1074 | 0 | 55.46 | 3 | [记录](rtl_dsp/fir_v5_20261018_220000/functional_board_frozen_seed3_20261018_221222_803428.json) |
| cip_iir_biquad_stream | 1096 | 0 | 60.14 | 3 | [记录](rtl_dsp/iir_optimized/case_v1/functional_board_accept_20261018_221914_20261018_222100_450911.json) |
| cip_fft_stream | 2486 | 0 | 54.58 | 3 | [记录](rtl_dsp/fft_optimized/case_v3/functional_board_frozen_seed3_20261018_223144_755180.json) |
| cip_cic_decimator | 962 | 0 | 66.12 | 3 | [记录](rtl_dsp/cic_optimized/case_v3/functional_board_frozen_seed3_20261018_221933_117423.json) |
| cip_resampler_stream | 1110 | 0 | 57.50 | 3 | [记录](rtl_dsp/resampler_optimized/case_v3/functional_board_accept_20261018_224626_20261018_224742_740696.json) |
| cip_cordic_stream | 1505 | 0 | 50.76 | 3 | [记录](rtl_dsp/cordic_v5_20261018_220000/functional_board_frozen_seed3_20261018_221246_893404.json) |
| cip_image_dehaze | 7961 | 0 | 53.76 | 3 | [记录](scalar_dehaze_optimized/dehaze_production_v3/functional_board_accept_20261019_004914_20261019_005237_474376.json) |
| cip_image_dark_channel | 1081 | 0 | 68.15 | 3 | [记录](scalar_dehaze_optimized/dark_channel_production_v2/functional_board_accept_20261019_004955_20261019_005059_826342.json) |
| cip_image_transmission | 1380 | 0 | 67.53 | 3 | [记录](scalar_dehaze_optimized/transmission_production_v3/functional_board_accept_20261019_005059_20261019_005144_657129.json) |
| cip_image_recover | 1463 | 0 | 61.86 | 3 | [记录](scalar_dehaze_optimized/recover_v3/functional_board_accept_20261018_230429_20261018_230701_464758.json) |
| cip_image_scaler | 9127 | 0 | 55.87 | 3 | [记录](geo_optimized/scaler_production_v10/functional_board_accept_20261019_011217_20261019_012947_013658.json) |
| cip_image_rotate | 12191 | 0 | 56.36 | 3 | [记录](geo_mapping_optimized/rotate_current_v8/functional_board_rotate_current_20261019_20261019_012514_093295.json) |
| cip_image_downsample | 2185 | 0 | 76.27 | 3 | [记录](geo_optimized/downsample_production_v5/functional_board_accept_20261019_011227_20261019_011415_371002.json) |
| cip_image_upsample | 6856 | 0 | 62.79 | 3 | [记录](geo_optimized/upsample_production_v6/functional_board_accept_20261019_011157_20261019_011517_219809.json) |
| cip_image_super_resolution | 4893 | 0 | 61.30 | 3 | [记录](scalar_dehaze_optimized/super_resolution_rtl_v7/functional_board_frozen_seed3_20261019_011832_039999.json) |
| cip_image_window | 2015 | 0 | 57.66 | 3 | [记录](window_frame_optimized/window_v2/functional_board_frozen_seed3_20261018_223504_036278.json) |
| cip_image_color_convert | 1644 | 0 | 57.75 | 3 | [记录](cases/color_optimized_v2/functional_board_color_rom_20261018_20261018_223926_776016.json) |
| cip_image_framebuffer | 1556 | 0 | 72.84 | 3 | [记录](scalar_dehaze_optimized/framebuffer_counts_v9/functional_board_accept_20261018_235527_20261018_235622_015590.json) |
| cip_image_bayer_demosaic | 1220 | 0 | 63.34 | 3 | [记录](cases/bayer_demosaic_v1/functional_board_accept_20261018_224900_20261018_225036_647168.json) |
| cip_image_gamma | 2057 | 0 | 54.55 | 3 | [记录](cases/gamma_v3/functional_board_accept_20261018_220351_20261018_221137_650102.json) |
| cip_image_awb | 3961 | 0 | 50.73 | 3 | [记录](scalar_dehaze_optimized/awb_counts_v4/functional_board_accept_20261018_233640_20261018_233956_571628.json) |
| cip_image_ccm | 5317 | 0 | 52.05 | 3 | [记录](scalar_dehaze_optimized/ccm_harness_v3/functional_board_accept_20261018_231347_20261018_231552_269517.json) |
| cip_image_histogram | 968 | 0 | 78.30 | 3 | [记录](cases/histogram_production_v2/functional_board_hist_production_20261018_20261018_222632_137209.json) |
| cip_image_he | 1122 | 0 | 70.80 | 3 | [记录](cases/he_mapping_v2/functional_board_he_width_20261018_20261018_222123_588665.json) |
| cip_image_clahe | 4070 | 0 | 51.95 | 3 | [记录](clahe_optimized/case_v8/functional_board_clahe_bounded_count_v8_20261018_235223_269108.json) |
| cip_image_brightness_contrast | 2226 | 0 | 52.86 | 3 | [记录](cases/brightness_v5/functional_board_frozen_seed3_20261018_221115_855933.json) |
| cip_image_mean_filter | 1266 | 0 | 66.88 | 3 | [记录](scalar_dehaze_optimized/mean_filter_production_v6/functional_board_accept_20261019_003750_20261019_003837_159146.json) |
| cip_image_gaussian_filter | 1239 | 0 | 73.41 | 3 | [记录](scalar_dehaze_optimized/gaussian_filter_production_v6/functional_board_accept_20261019_003838_20261019_003922_087285.json) |
| cip_image_median_filter | 1824 | 0 | 60.81 | 3 | [记录](cases/median_pipeline_v6/functional_board_median_pipeline5_20261018_20261018_233627_049199.json) |
| cip_image_bilateral_filter | 2162 | 0 | 62.72 | 3 | [记录](scalar_dehaze_optimized/bilateral_rom_v9/functional_board_accept_20261019_002227_20261019_002501_187318.json) |
| cip_image_guided_filter | 5373 | 0 | 50.21 | 3 | [记录](scalar_dehaze_optimized/guided_harness_v2/functional_board_guided_seed7_20261019_20261019_001706_497786.json) |
| cip_image_temporal_denoise | 919 | 0 | 92.93 | 3 | [记录](scalar_dehaze_optimized/temporal_v2/functional_board_accept_20261018_230511_20261018_230556_788504.json) |
| cip_image_nlm_denoise | 3470 | 0 | 53.15 | 3 | [记录](nlm_optimized/case_v10/functional_board_nlm_bounded_control_v10_20261019_004733_573478.json) |
| cip_image_sobel | 1345 | 0 | 70.14 | 3 | [记录](scalar_dehaze_optimized/sobel_production_v6/functional_board_accept_20261019_003923_20261019_004016_762821.json) |
| cip_image_prewitt | 1338 | 0 | 66.21 | 3 | [记录](scalar_dehaze_optimized/prewitt_production_v6/functional_board_accept_20261019_004019_20261019_004124_186944.json) |
| cip_image_canny | 2048 | 0 | 53.12 | 3 | [记录](cases/canny_v1/functional_board_accept_20261018_231844_20261018_232156_125848.json) |
| cip_image_laplacian | 1200 | 0 | 66.23 | 3 | [记录](scalar_dehaze_optimized/laplacian_production_v6/functional_board_accept_20261019_004127_20261019_004223_632601.json) |
| cip_image_threshold | 4042 | 0 | 52.06 | 3 | [记录](cases/threshold_optimized_v10/functional_board_threshold_counts_seed5_20261018_20261018_232946_928772.json) |
| cip_image_morphology | 1835 | 0 | 50.14 | 3 | [记录](cases/morphology_mapping_v3/functional_board_morph_addr_20261018_20261018_225909_026666.json) |
| cip_image_affine | 9750 | 0 | 56.14 | 3 | [记录](geo_mapping_optimized/affine_current_v5/functional_board_affine_current_20261019_20261019_012309_345774.json) |
| cip_image_mirror_flip | 1074 | 0 | 60.92 | 3 | [记录](cases/mirror_v1/functional_board_mirror_20261018_no_lutram_20261018_221633_631936.json) |
| cip_image_invert | 1144 | 0 | 53.36 | 3 | [记录](cases/invert_v1/functional_board_accept_20261018_220351_20261018_221200_680135.json) |
| cip_image_perspective | 9545 | 0 | 51.81 | 3 | [记录](geo_mapping_optimized/perspective_current_v5/functional_board_perspective_current_20261019_20261019_012349_232487.json) |
| cip_image_osd | 1519 | 0 | 74.65 | 3 | [记录](scalar_dehaze_optimized/osd_harness_v2/functional_board_accept_20261018_231023_20261018_231152_836183.json) |
| cip_image_frame_difference | 871 | 0 | 88.96 | 3 | [记录](window_frame_optimized/frame_difference_v5/functional_board_frozen_seed3_20261018_224128_445340.json) |
| cip_image_background_model | 1018 | 0 | 62.47 | 3 | [记录](scalar_dehaze_optimized/background_model_pipeline_v4/functional_board_accept_20261018_234303_20261018_234352_298692.json) |
| cip_image_stitch | 3238 | 0 | 55.17 | 3 | [记录](scalar_dehaze_optimized/stitch_production_v6/functional_board_accept_20261019_011832_20261019_012106_721781.json) |
| cip_image_fusion | 2155 | 0 | 53.08 | 3 | [记录](cases/fusion_counts_v7/functional_board_fusion_counts_20261018_20261018_235729_986346.json) |

当前版本文件哈希见 FINAL_PRODUCTION_SOURCE_SHA256.json；逐候选、回归与失败记录见 acceptance_status.json 和 LIVE_STATUS.md。
临时仿真二进制和本轮使用后的临时位流已清理；源代码、冻结输入、布局布线结果、日志与哈希记录保留。

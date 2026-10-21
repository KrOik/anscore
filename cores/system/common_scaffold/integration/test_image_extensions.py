"""Run independent extension regressions without modifying acceptance48."""
import hashlib
import sys
from pathlib import Path

from tooling import ROOT, PACKAGE, evidence_dir, execute, write_json


CASES = (
    ('raw16_pack', 'image/raw16_codec/run_tests.py', 'image/raw16_codec/raw16_pack.sv'),
    ('raw16_unpack', 'image/raw16_codec/test_roundtrip.py', 'image/raw16_codec/raw16_unpack.sv'),
    ('i2c_eeprom', 'peripherals/i2c_eeprom/test_case.py', 'peripherals/i2c_eeprom/i2c_eeprom.sv'),
    ('spi_nor_flash', 'peripherals/spi_nor_flash/run_tests.py', 'peripherals/spi_nor_flash/spi_nor_flash.sv'),
    ('raw14_pack', 'image/raw14_codec/run_tests.py', 'image/raw14_codec/raw14_pack.sv'),
    ('raw14_unpack', 'image/raw14_codec/test_roundtrip.py', 'image/raw14_codec/raw14_unpack.sv'),
    ('axi_multi_crossbar', 'stream_bus/axi_multi_crossbar/run_tests.py', 'stream_bus/axi_multi_crossbar/axi_multi_crossbar.sv'),
    ('tdm_audio_rx', 'peripherals/tdm_audio/run_tests.py', 'peripherals/tdm_audio/tdm_audio_rx.sv'),
    ('tdm_audio_tx', 'peripherals/tdm_audio/test_roundtrip.py', 'peripherals/tdm_audio/tdm_audio_tx.sv'),
    ('pulse_measurement', 'peripherals/pulse_measurement/test_case.py', 'peripherals/pulse_measurement/pulse_measurement.sv'),
    ('onewire_rom_search', 'peripherals/onewire_rom_search/run_tests.py', 'peripherals/onewire_rom_search/onewire_rom_search.sv'),
    ('frequency_counter', 'peripherals/frequency_counter/run_tests.py', 'peripherals/frequency_counter/frequency_counter.sv'),
    ('ds18b20_temperature', 'peripherals/ds18b20_temperature/test_case.py', 'peripherals/ds18b20_temperature/ds18b20_temperature.sv'),
    ('video_frame_rate_converter', 'image/video_frame_rate_converter/run_tests.py', 'image/video_frame_rate_converter/video_frame_rate_converter.sv'),
    ("tmds_encoder", "image/tmds_codec/test_encoder.py", "image/tmds_codec/tmds_encoder.sv"),
    ("tmds_decoder", "image/tmds_codec/test_decoder.py", "image/tmds_codec/tmds_decoder.sv"),
    ("ps2_host", "peripherals/ps2_host/run_tests.py", "peripherals/ps2_host/ps2_host.sv"),
    ("lcd8080", "peripherals/lcd8080/test_case.py", "peripherals/lcd8080/lcd8080_engine.sv"),
    ("axil_multi_crossbar", "stream_bus/axil_multi_crossbar/run_tests.py", "stream_bus/axil_multi_crossbar/axil_multi_crossbar.sv"),
    ("video_timing_generator", "image/video_scanout/test_timing_case.py", "image/video_scanout/video_timing_generator.sv"),
    ("video_rgb_scanout", "image/video_scanout/test_scanout_case.py", "image/video_scanout/video_rgb_scanout.sv"),
    ("dvp_tx", "image/dvp_tx/run_tests.py", "image/dvp_tx/dvp_tx.sv"),
    ("bt656_tx", "image/bt656_tx/run_tests.py", "image/bt656_tx/bt656_tx.sv"),
    ("video_stream_to_axis", "image/axi_video_bridge/test_to_axis.py", "image/axi_video_bridge/video_stream_to_axis.sv"),
    ("axis_to_video_stream", "image/axi_video_bridge/test_from_axis.py", "image/axi_video_bridge/axis_to_video_stream.sv"),
    ("dvp_rx", "image/dvp_rx/run_tests.py", "image/dvp_rx/dvp_rx.sv"),
    ("tiff_encoder", "image/tiff_encoder/run_tests.py", "image/tiff_encoder/tiff_encoder.sv"),
    ("tiff_decoder", "image/tiff_decoder/run_tests.py", "image/tiff_decoder/tiff_decoder.sv"),
    ("csi2_packet_tx", "image/csi2_packet_tx/run_tests.py", "image/csi2_packet_tx/csi2_packet_tx.sv"),
    ("video_dma_2d", "memory/video_dma_2d/run_tests.py", "memory/video_dma_2d/video_dma_2d_axi32.v"),
    ("bt656_rx", "image/bt656_rx/run_tests.py", "image/bt656_rx/bt656_rx.sv"),
    ("yuv422_byte_packer", "image/yuv422_bytes/test_packer.py", "image/yuv422_bytes/yuv422_byte_packer.sv"),
    ("yuv422_byte_unpacker", "image/yuv422_bytes/test_unpacker.py", "image/yuv422_bytes/yuv422_byte_unpacker.sv"),
    ("csi2_packet_rx", "image/csi2_packet_rx/run_tests.py", "image/csi2_packet_rx/csi2_packet_rx.sv"),
    ("bmp_encoder", "image/bmp_encoder/run_tests.py", "image/bmp_encoder/bmp_encoder.sv"),
    ("bmp_decoder", "image/bmp_decoder/run_tests.py", "image/bmp_decoder/bmp_decoder.sv"),
    ("png_encoder", "image/png_encoder/run_tests.py", "image/png_encoder/png_encoder.sv"),
    ("png_decoder", "image/png_decoder/run_tests.py", "image/png_decoder/png_decoder.sv"),
    ("integral_image", "image/integral_image/run_tests.py", "image/integral_image/integral_image.sv"),
    ("raw_black_level", "image/raw_black_level/run_tests.py", "image/raw_black_level/raw_black_level.sv"),
    ("raw_white_balance", "image/raw_white_balance/run_tests.py", "image/raw_white_balance/raw_white_balance.sv"),
    ("defect_map", "image/defect_map/run_tests.py", "image/defect_map/defect_map.sv"),
    ("malvar_demosaic", "image/malvar_demosaic/run_tests.py", "image/malvar_demosaic/malvar_demosaic.sv"),
    ("lens_shading", "image/lens_shading/run_tests.py", "image/lens_shading/lens_shading.sv"),
    ("raw_gamma", "image/raw_gamma/run_tests.py", "image/raw_gamma/raw_gamma.sv"),
    ("stereo_rectify", "image/stereo_rectify/run_tests.py", "image/stereo_rectify/stereo_rectify.sv"),
    ("stereo_subpixel", "image/stereo_subpixel/run_tests.py", "image/stereo_subpixel/stereo_subpixel.sv"),
    ("disparity_speckle", "image/disparity_speckle/run_tests.py", "image/disparity_speckle/disparity_speckle.sv"),
    ("jpeg_color_decoder", "image/jpeg_color_decoder/run_tests.py", "image/jpeg_color_decoder/jpeg_color_decoder.sv"),
    ("multiscale_features", "image/multiscale_features/run_tests.py", "image/multiscale_features/multiscale_features_frame.sv"),
    ("disparity_reproject", "image/disparity_reproject/run_tests.py", "image/disparity_reproject/disparity_reproject.sv"),
    ("stereo_sgm", "image/stereo_sgm/run_tests.py", "image/stereo_sgm/stereo_sgm.sv"),
    ("oriented_brief", "image/oriented_brief/run_tests.py", "image/oriented_brief/oriented_brief_frame.sv"),
    ("jpeg_gray_decoder", "image/jpeg_gray_decoder/run_tests.py", "image/jpeg_gray_decoder/jpeg_gray_decoder.sv"),
    ("entropy_filter", "image/entropy_filter/run_tests.py", "image/entropy_filter/entropy_filter_frame.sv"),
    ("multi_otsu", "image/multi_otsu/test_multi_otsu.py", "image/multi_otsu/multi_otsu.sv"),
    ("chamfer_match", "image/chamfer_match/run_tests.py", "image/chamfer_match/chamfer_match.sv"),
    ("gabor_filter", "image/gabor_filter/run_tests.py", "image/gabor_filter/gabor_filter_frame.sv"),
    ("niblack", "image/niblack/test_niblack.py", "image/niblack/niblack.sv"),
    ("hough_segments", "image/hough_segments/run_tests.py", "image/hough_segments/hough_segments.sv"),
    ("hough_segment_pipeline", "image/hough_segment_pipeline/run_tests.py", "image/hough_segment_pipeline/hough_segment_pipeline.sv"),
    ("mean_shift", "image/mean_shift/run_tests.py", "image/mean_shift/mean_shift_frame.sv"),
    ("wiener_denoise", "image/wiener_denoise/test_wiener.py", "image/wiener_denoise/wiener_denoise.sv"),
    ("hough_lines_full", "image/hough_lines_full/run_tests.py", "image/hough_lines_full/hough_lines_full.sv"),
    ("template_match", "image/template_match/run_tests.py", "image/template_match/template_match_zncc.sv"),
    ("phase_registration", "image/phase_registration/test_registration.py", "image/phase_registration/phase_registration.sv"),
    ("hough_circles", "image/hough_circles/run_tests.py", "image/hough_circles/hough_circles_frame.v"),
    ("seam_multiband_blend", "image/seam_multiband_blend/test_pipeline.py", "image/seam_multiband_blend/seam_multiband_blend.sv"),
    ("unsharp_mask", "image/unsharp_mask/run_tests.py", "image/unsharp_mask/unsharp_mask_frame.sv"),
    ("seam_find", "image/seam_find/test_seam.py", "image/seam_find/seam_find.sv"),
    ("poisson_blend", "image/poisson_blend/run_tests.py", "image/poisson_blend/poisson_blend_frame.sv"),
    ("phase_correlation", "image/phase_correlation/run_tests.py", "image/phase_correlation/phase_correlation_frame.v"),
    ("cielab_color", "image/cielab_color/run_tests.py", "image/cielab_color/rgb_cielab_stream.v"),
    ("kmeans_segmentation", "image/kmeans_segmentation/run_tests.py", "image/kmeans_segmentation/kmeans_rgb_frame.sv"),
    ("multiband_blend", "image/multiband_blend/test_multiband.py", "image/multiband_blend/multiband_blend.sv"),
    ("lab_kmeans_quantizer", "integration/test_lab_kmeans_quantizer.py", "image/lab_kmeans_quantizer/lab_kmeans_quantizer.sv"),
    ("mog3_background", "image/mog3_background/run_tests.py", "image/mog3_background/mog3_background_frame.sv"),
    ("homography_ransac", "image/homography_ransac/test_homography_ransac.py", "image/homography_ransac/homography_ransac.sv"),
    ("hsv_color", "image/hsv_color/test_hsv_color.py", "image/hsv_color/rgb_hsv_full_stream.v"),
    ("jpeg_color_headers", "dsp/jpeg_color_headers/test_headers.py", "dsp/jpeg_color_headers/jpeg_color_headers.sv"),
    ("jpeg_color_scan", "dsp/jpeg_color_scan/test_color_scan.py", "dsp/jpeg_color_scan/jpeg_color_scan.sv"),
    ("jpeg_color_mcu", "image/jpeg_color_mcu/test_jpeg_color_mcu.py", "image/jpeg_color_mcu/jpeg_color_mcu.v"),
    ("jpeg_color_frame", "integration/test_jpeg_color_frame.py", "dsp/jpeg_color_frame/jpeg_color_frame.sv"),
    ("ae", "image/auto_exposure/run_tests.py", "image/auto_exposure/img_ae_controller.v"),
    ("chroma422", "image/chroma_reconstruct/upsample422/test_upsample422.py",
     "image/chroma_reconstruct/upsample422/chroma_upsample422.v"),
    ("chroma420", "image/chroma_reconstruct/upsample420/test_reconstruct.py",
     "image/chroma_reconstruct/upsample420/chroma_420_to_444.sv"),
    ("stats_ae_bridge", "image/ae_stats_bridge/run_tests.py",
     "image/ae_stats_bridge/ispstats_ae_bridge.sv"),
    ("raw_unpack", "image/raw_unpack/run_tests.py", "image/raw_unpack/img_csi2_raw_unpack.v"),
    ("asrc", "dsp/asrc/test_asrc.py", "dsp/asrc/asrc_linear.sv"),
    ("hdr_dol", "image/hdr_dol/test_hdr_dol.py", "image/hdr_dol/raw_hdr_dol.v"),
    ("rgb565", "image/rgb565/run_tests.py", "image/rgb565/rgb565_stream.sv"),
    ("raw_pack", "image/raw_pack/run_tests.py", "image/raw_pack/img_csi2_raw_pack.v"),
    ("dct8x8", "dsp/dct8x8/test_dct.py", "dsp/dct8x8/dct8x8_serial.sv"),
    ("autofocus", "image/autofocus/test_autofocus.py", "image/autofocus/contrast_af_controller.v"),
    ("jpeg_bitstream", "dsp/jpeg_bitstream/run_tests.py", "dsp/jpeg_bitstream/jpeg_entropy_bitpacker.sv"),
    ("jpeg_quant_zigzag", "dsp/jpeg_quant_zigzag/test_quant.py", "dsp/jpeg_quant_zigzag/jpeg_quant_zigzag.sv"),
    ("jpeg_entropy", "dsp/jpeg_entropy/test_jpeg_symbols.py", "dsp/jpeg_entropy/jpeg_baseline_symbols.v"),
    ("jpeg_huffman", "dsp/jpeg_huffman/test_huffman.py", "dsp/jpeg_huffman/jpeg_default_huffman.sv"),
    ("nv12_layout", "image/nv12_layout/run_tests.py", "image/nv12_layout/img_nv12_layout.v"),
    ("raster_blocks", "image/raster_blocks/run_tests.py", "image/raster_blocks/img_raster_blocks.v"),
    ("jpeg_headers", "dsp/jpeg_headers/test_headers.py", "dsp/jpeg_headers/jpeg_gray_headers.sv"),
    ("jpeg_scan_control", "dsp/jpeg_scan_control/test_scan_control.py", "dsp/jpeg_scan_control/jpeg_entropy_scan_controller.v"),
    ("jpeg_grayscale", "integration/test_jpeg_frame.py", "dsp/jpeg_grayscale/jpeg_grayscale_scan.sv"),
    ("fast9", "image/fast9/run_tests.py", "image/fast9/img_fast9_frame.sv"),
    ("connected_components", "image/connected_components/run_tests.py", "image/connected_components/img_connected_components.v"),
    ("distance_transform", "image/distance_transform/test_distance.py", "image/distance_transform/binary_distance_transform.sv"),
    ("hough_lines", "image/hough_lines/test_hough_lines.py", "image/hough_lines/hough_lines4.v"),
    ("bad_pixel", "image/bad_pixel/run_tests.py", "image/bad_pixel/raw_bad_pixel_frame.sv"),
    ("census", "image/census/run_tests.py", "image/census/img_census_frame.sv"),
    ("stereo_census", "image/stereo_census/run_tests.py", "image/stereo_census/stereo_census_match_frame.sv"),
    ("gaussian_pyramid", "image/gaussian_pyramid/run_tests.py", "image/gaussian_pyramid/img_gaussian_pyramid_frame.sv"),
    ("stereo_lr_check", "image/stereo_lr_check/run_tests.py", "image/stereo_lr_check/img_stereo_lr_check.v"),
    ("haar2d", "dsp/haar2d/test_haar.py", "dsp/haar2d/haar2d_lifting.sv"),
    ("color_lut3d", "image/color_lut3d/test_color_lut3d.py", "image/color_lut3d/color_lut3d.v"),
    ("block_motion", "image/block_motion/run_tests.py", "image/block_motion/img_block_motion.v"),
    ("median_background", "image/median_background/test_median_background.py", "image/median_background/temporal_median_background.sv"),
    ("hog", "image/hog/test_hog.py", "image/hog/hog_l1_9.v"),
    ("corner_nms", "image/corner_nms/run_tests.py", "image/corner_nms/img_corner_nms.v"),
    ("brief", "image/brief/test_brief.py", "image/brief/brief_descriptor.sv"),
    ("sauvola", "image/sauvola/test_sauvola.py", "image/sauvola/sauvola_frame.v"),
    ("descriptor_match", "image/descriptor_match/test_descriptor_match.py", "image/descriptor_match/descriptor_match.sv"),
    ("thinning", "image/thinning/test_thinning.py", "image/thinning/zhang_suen_thinning.sv"),
    ("histogram_match", "image/histogram_match/test_histogram_match.py", "image/histogram_match/histogram_match_frame.v"),
    ("hole_fill", "image/hole_fill/test_hole_fill.py", "image/hole_fill/binary_hole_fill.sv"),
    ("motion_compensation", "image/motion_compensation/run_tests.py", "image/motion_compensation/motion_compensation.sv"),
    ("glcm", "image/glcm/test_glcm.py", "image/glcm/glcm_frame.v"),
    ("euclidean_distance", "image/euclidean_distance/run_tests.py", "image/euclidean_distance/euclidean_distance.sv"),
    ("moments", "image/moments/test_moments.py", "image/moments/image_spatial_moments.sv"),
    ("morph_reconstruction", "image/morph_reconstruction/test_morph_reconstruct.py", "image/morph_reconstruction/morph_reconstruct_frame.v"),
    ("optical_flow", "image/optical_flow/test_optical_flow.py", "image/optical_flow/dense_lucas_kanade.sv"),
    ("binary_rle", "image/binary_rle/test_binary_rle.py", "image/binary_rle/binary_rle_encoder.v"),
    ("retinex", "image/retinex/run_tests.py", "image/retinex/retinex_ssr.sv"),
    ("error_diffusion", "image/error_diffusion/run_tests.py", "image/error_diffusion/floyd_steinberg.sv"),
    ("deinterlace", "image/deinterlace/test_deinterlace.py", "image/deinterlace/deinterlace_fields.sv"),
    ("watershed", "image/watershed/test_watershed.py", "image/watershed/watershed_priority_frame.v"),
    ("lens_distortion", "image/lens_distortion/run_tests.py", "image/lens_distortion/lens_distortion_map.sv"),
    ("affine_ransac", "image/affine_ransac/test_affine_ransac.py", "image/affine_ransac/affine_ransac.sv"),
    ("contours", "image/contours/test_contours.py", "image/contours/contours_cell_edges.v"),
    ("pyramidal_flow", "image/pyramidal_flow/test_pyramidal_flow.py", "image/pyramidal_flow/pyramidal_lk_flow.v"),
    ("video_stabilization", "image/video_stabilization/test_stabilization.py", "image/video_stabilization/affine_video_stabilizer.sv"),
    ("chromatic_aberration", "image/chromatic_aberration/run_tests.py", "image/chromatic_aberration/chromatic_aberration_frame.sv"),
)

INTEGRATIONS = (
    ('raw16_protocol', 'image/raw16_codec/test_protocol.py', []),
    ('raw16_roundtrip', 'image/raw16_codec/test_roundtrip.py', []),
    ('raw16_parameters', 'image/raw16_codec/test_parameters.py', []),
    ('raw16_control', 'image/raw16_codec/test_control.py', []),
    ('raw16_independent', 'integration/test_raw16_independent.py', []),
    ('raw16_peer_recovery', 'image/raw16_peer/test_error_recovery.py', []),
    ('i2c_eeprom_transactions', 'peripherals/i2c_eeprom/test_transactions.py', []),
    ('i2c_eeprom_boundaries', 'peripherals/i2c_eeprom/test_boundaries.py', []),
    ('i2c_eeprom_errors', 'peripherals/i2c_eeprom/test_errors.py', []),
    ('i2c_eeprom_parameters', 'peripherals/i2c_eeprom/test_parameters.py', []),
    ('i2c_eeprom_protocol', 'peripherals/i2c_eeprom/test_protocol.py', []),
    ('i2c_eeprom_independent_pins', 'peripherals/i2c_eeprom_peer/test_scripted_pins.py', []),
    ('spi_nor_independent_pins', 'integration/test_spi_nor_independent.py', []),
    ('raw14_protocol', 'image/raw14_codec/test_protocol.py', []),
    ('raw14_roundtrip', 'image/raw14_codec/test_roundtrip.py', []),
    ('raw14_parameters', 'image/raw14_codec/test_parameters.py', []),
    ('raw14_control', 'image/raw14_codec/test_control.py', []),
    ('raw14_bit_basis', 'integration/test_raw14_bit_basis.py', []),
    ('axi_crossbar_address_oracle', 'stream_bus/axi_crossbar_peer/address_oracle.py', ['--self-test']),
    ('axi_crossbar_five_channel', 'stream_bus/axi_crossbar_peer/test_five_channel.py', []),
    ('tdm_audio_protocol', 'peripherals/tdm_audio/test_protocol.py', []),
    ('tdm_audio_limits', 'peripherals/tdm_audio/test_limits.py', []),
    ('tdm_audio_parameters', 'peripherals/tdm_audio/test_parameters.py', []),
    ('pulse_measurement_full', 'peripherals/pulse_measurement/test_measurement.py', []),
    ('pulse_measurement_boundaries', 'peripherals/pulse_measurement/test_boundaries.py', []),
    ('pulse_measurement_protocol', 'peripherals/pulse_measurement/test_protocol.py', []),
    ('pulse_measurement_parameters', 'peripherals/pulse_measurement/test_parameters.py', []),
    ('pulse_measurement_quantization', 'peripherals/pulse_measurement/test_quantization.py', []),
    ('onewire_rom_search_branches', 'peripherals/onewire_rom_search/test_branches.py', []),
    ('onewire_rom_search_protocol', 'peripherals/onewire_rom_search/test_protocol.py', []),
    ('onewire_rom_search_numeric', 'peripherals/onewire_rom_search/test_numeric_limits.py', []),
    ('frequency_counter_boundaries', 'peripherals/frequency_counter/test_boundaries.py', []),
    ('frequency_counter_protocol', 'peripherals/frequency_counter/test_protocol.py', []),
    ('frequency_counter_parameters', 'peripherals/frequency_counter/test_parameters.py', []),
    ('ds18b20_temperature_temperature', 'peripherals/ds18b20_temperature/test_temperature.py', []),
    ('ds18b20_temperature_timing', 'peripherals/ds18b20_temperature/test_timing.py', []),
    ('ds18b20_temperature_protocol', 'peripherals/ds18b20_temperature/test_protocol.py', []),
    ('ds18b20_temperature_parameters', 'peripherals/ds18b20_temperature/test_parameters.py', []),
    ('ds18b20_temperature_long_conversion', 'peripherals/ds18b20_temperature/test_long_conversion.py', []),
    ('video_frc_protocol', 'image/video_frame_rate_converter/test_protocol.py', []),
    ('video_frc_numeric_limits', 'image/video_frame_rate_converter/test_numeric_limits.py', []),
    ('video_frc_parameters', 'image/video_frame_rate_converter/test_parameters.py', []),
    ('video_frc_control', 'image/video_frame_rate_converter/test_control.py', []),
    ('video_frc_root_peer', 'integration/peer_review_video_frc.py', []),
    ('dvp_rx_ring', 'image/dvp_rx/test_ring.py', []),
    ('tmds_protocol', 'image/tmds_codec/test_protocol.py', []),
    ('tmds_throughput', 'image/tmds_codec/test_throughput.py', []),
    ('tmds_rgb_roundtrip', 'image/tmds_codec/test_rgb_roundtrip.py', []),
    ('tmds_projectf_reference', 'image/tmds_codec/test_reference.py', []),
    ('raster_tmds_rgb', 'integration/test_raster_tmds_rgb.py', []),
    ('ps2_protocol', 'peripherals/ps2_host/test_protocol.py', []),
    ('ps2_parameters', 'peripherals/ps2_host/test_parameters.py', []),
    ('ps2_numeric_limits', 'peripherals/ps2_host/test_numeric_limits.py', []),
    ('lcd8080_protocol', 'peripherals/lcd8080/test_lcd8080.py', []),
    ('lcd8080_boundaries', 'peripherals/lcd8080/test_boundaries.py', []),
    ('lcd8080_parameters', 'peripherals/lcd8080/test_parameters.py', []),
    ('video_scanout_fault_boundaries', 'image/video_scanout/test_fault_boundaries.py', []),
    ('axil_multi_fairness', 'stream_bus/axil_multi_crossbar/test_fairness.py', []),
    ('axil_multi_parameters', 'stream_bus/axil_multi_crossbar/test_parameters.py', []),
    ('axil_multi_reset', 'stream_bus/axil_multi_crossbar/test_reset.py', []),
    ('video_timing_full', 'image/video_scanout/test_timing.py', []),
    ('video_scanout_full', 'image/video_scanout/test_scanout.py', []),
    ('video_timing_protocol', 'image/video_scanout/test_timing_protocol.py', []),
    ('video_scanout_protocol', 'image/video_scanout/test_protocol.py', []),
    ('video_scanout_parameters', 'image/video_scanout/test_parameters.py', []),
    ('video_scanout_dense_numeric', 'image/video_scanout/test_dense_numeric.py', []),
    ('dvp_tx_protocol', 'image/dvp_tx/test_protocol.py', []),
    ('dvp_tx_numeric_limits', 'image/dvp_tx/test_numeric_limits.py', []),
    ('dvp_tx_rx_axi', 'integration/test_dvp_tx_rx_axi.py', []),
    ('dvp_rx_protocol', 'image/dvp_rx/test_protocol.py', []),
    ('dvp_rx_numeric_limits', 'image/dvp_rx/test_numeric_limits.py', []),
    ('bt656_tx_protocol', 'image/bt656_tx/test_protocol.py', []),
    ('bt656_tx_numeric', 'image/bt656_tx/test_numeric.py', []),
    ('axi_video_roundtrip', 'image/axi_video_bridge/run_tests.py', []),
    ('axi_video_protocol', 'image/axi_video_bridge/test_protocol.py', []),
    ('axi_video_parameters', 'image/axi_video_bridge/test_parameters.py', []),
    ('axi_video_throughput', 'image/axi_video_bridge/test_throughput.py', []),
    ('bt656_tx_rx_yuv', 'integration/test_bt656_tx_rx_yuv.py', []),
    ('dvp_axi_video', 'integration/test_dvp_axi_video.py', []),
    ('tiff_encoder_protocol', 'image/tiff_encoder/test_protocol.py', []),
    ('tiff_encoder_parameters', 'image/tiff_encoder/test_parameters.py', []),
    ('tiff_decoder_errors', 'image/tiff_decoder/test_errors.py', []),
    ('tiff_decoder_protocol', 'image/tiff_decoder/test_protocol.py', []),
    ('tiff_decoder_numeric_limits', 'image/tiff_decoder/test_numeric_limits.py', []),
    ('csi2_tx_protocol', 'image/csi2_packet_tx/test_protocol.py', []),
    ('tiff_codec_chain', 'integration/test_tiff_codec_chain.py', []),
    ('csi2_tx_rx', 'integration/test_csi2_tx_rx.py', []),
    ('yuv422_byte_protocol', 'image/yuv422_bytes/test_protocol.py', []),
    ('yuv422_byte_parameters', 'image/yuv422_bytes/test_parameters.py', []),
    ('bt656_rx_protocol', 'image/bt656_rx/test_protocol.py', []),
    ('video_dma_yuv', 'integration/test_video_dma_yuv.py', []),
    ('bt656_yuv', 'integration/test_bt656_yuv.py', []),
    ('csi2_packet_protocol', 'image/csi2_packet_rx/test_protocol.py', []),
    ('csi2_packet_numeric', 'image/csi2_packet_rx/test_numeric.py', []),
    ('csi2_raw', 'integration/test_csi2_raw.py', []),
    ('bmp_encoder_protocol', 'image/bmp_encoder/test_protocol.py', []),
    ('bmp_encoder_parameters', 'image/bmp_encoder/test_parameters.py', []),
    ('bmp_decoder_protocol', 'image/bmp_decoder/test_protocol.py', []),
    ('bmp_decoder_numeric', 'image/bmp_decoder/test_numeric_limits.py', []),
    ('bmp_codec', 'integration/test_bmp_codec.py', []),
    ('bmp_codec_synthesis', 'integration/synth_bmp_codec.py', []),
    ('png_encoder_protocol', 'image/png_encoder/test_protocol.py', []),
    ('png_encoder_numeric', 'image/png_encoder/test_numeric_limits.py', []),
    ('png_encoder_parameters', 'image/png_encoder/test_parameters.py', []),
    ('png_decoder_protocol', 'image/png_decoder/test_protocol.py', []),
    ('png_decoder_errors', 'image/png_decoder/test_errors.py', []),
    ('png_decoder_deflate_limits', 'image/png_decoder/test_deflate_limits.py', []),
    ('png_decoder_numeric', 'image/png_decoder/test_numeric_limits.py', []),
    ('png_codec', 'integration/test_png_codec.py', []),
    ('png_transcode', 'integration/test_png_transcode.py', []),
    ('png_codec_synthesis', 'integration/synth_png_codec.py', []),
    ('integral_image_protocol', 'image/integral_image/test_protocol.py', []),
    ('integral_image_numeric', 'image/integral_image/test_numeric_limits.py', []),
    ('raw_integral', 'integration/test_raw_integral.py', []),
    ('raw_black_level_protocol', 'image/raw_black_level/test_protocol.py', []),
    ('raw_black_level_parameters', 'image/raw_black_level/test_parameters.py', []),
    ('raw_white_balance_protocol', 'image/raw_white_balance/test_protocol.py', []),
    ('raw_white_balance_numeric', 'image/raw_white_balance/test_numeric_limits.py', []),
    ('raw_white_balance_reference', 'image/raw_white_balance/test_reference.py', []),
    ('defect_map_protocol', 'image/defect_map/test_protocol.py', []),
    ('defect_map_numeric', 'image/defect_map/test_numeric_limits.py', []),
    ('raw_calibration', 'integration/test_raw_calibration.py', []),
    ('malvar_protocol', 'image/malvar_demosaic/test_protocol.py', []),
    ('malvar_numeric', 'image/malvar_demosaic/test_numeric_limits.py', []),
    ('malvar_reference', 'image/malvar_demosaic/test_reference.py', []),
    ('lens_shading_protocol', 'image/lens_shading/test_protocol.py', []),
    ('lens_shading_numeric', 'image/lens_shading/test_numeric_limits.py', []),
    ('raw_gamma_protocol', 'image/raw_gamma/test_protocol.py', []),
    ('raw_gamma_numeric', 'image/raw_gamma/test_numeric_limits.py', []),
    ('lens_malvar', 'integration/test_lens_malvar.py', []),
    ('lens_malvar_gamma', 'integration/test_lens_malvar_gamma.py', []),
    ('stereo_rectify_protocol', 'image/stereo_rectify/test_protocol.py', []),
    ('stereo_rectify_numeric', 'image/stereo_rectify/test_numeric_limits.py', []),
    ('stereo_subpixel_protocol', 'image/stereo_subpixel/test_protocol.py', []),
    ('stereo_subpixel_numeric', 'image/stereo_subpixel/test_numeric_limits.py', []),
    ('stereo_subpixel_reference_variant', 'image/stereo_subpixel/test_reference_variant.py', []),
    ('disparity_speckle_protocol', 'image/disparity_speckle/test_protocol.py', []),
    ('disparity_speckle_numeric', 'image/disparity_speckle/test_numeric_limits.py', []),
    ('multiscale_match', 'integration/test_multiscale_match.py', []),
    ('sgm_speckle_reproject', 'integration/test_sgm_speckle_reproject.py', []),
    ('jpeg_color_decoder_protocol', 'image/jpeg_color_decoder/test_protocol.py', []),
    ('jpeg_color_decoder_numeric', 'image/jpeg_color_decoder/test_numeric_limits.py', []),
    ('jpeg_color_decoder_narrow', 'image/jpeg_color_decoder/test_narrow.py', []),
    ('multiscale_external', 'image/multiscale_features/test_external.py', []),
    ('multiscale_rom_binding', 'image/multiscale_features/test_rom_binding.py', []),
    ('disparity_reproject_protocol', 'image/disparity_reproject/test_protocol.py', []),
    ('disparity_reproject_numeric', 'image/disparity_reproject/test_numeric_limits.py', []),
    ('sgm_reproject', 'integration/test_sgm_reproject.py', []),
    ('jpeg_color_codec_roundtrip', 'integration/test_jpeg_color_codec_roundtrip.py', []),
    ('stereo_sgm_protocol', 'image/stereo_sgm/test_protocol.py', []),
    ('stereo_sgm_numeric', 'image/stereo_sgm/test_numeric_limits.py', []),
    ('jpeg_gray_decoder_protocol', 'image/jpeg_gray_decoder/test_protocol.py', []),
    ('jpeg_gray_decoder_numeric', 'image/jpeg_gray_decoder/test_numeric_limits.py', []),
    ('census_sgm', 'integration/test_census_sgm.py', []),
    ('fast_oriented_brief', 'integration/test_fast_oriented_brief.py', []),
    ('jpeg_codec_roundtrip', 'integration/test_jpeg_codec_roundtrip.py', []),
    ('multi_otsu_errors', 'image/multi_otsu/test_errors.py', []),
    ('chamfer_protocol', 'image/chamfer_match/test_protocol.py', []),
    ('chamfer_invalid_parameters', 'image/chamfer_match/test_invalid_parameters.py', []),
    ('chamfer_numeric_limits', 'image/chamfer_match/test_numeric_limits.py', []),
    ('niblack_errors', 'image/niblack/test_errors.py', []),
    ('hough_segments_protocol', 'image/hough_segments/test_protocol.py', []),
    ('hough_segments_invalid_parameters', 'image/hough_segments/test_invalid_parameters.py', []),
    ('hough_pipeline_protocol', 'image/hough_segment_pipeline/test_protocol.py', []),
    ('hough_pipeline_invalid_parameters', 'image/hough_segment_pipeline/test_invalid_parameters.py', []),
    ('wiener_errors', 'image/wiener_denoise/test_errors.py', []),
    ('hough_lines_protocol', 'image/hough_lines_full/test_protocol.py', []),
    ('hough_lines_invalid_parameters', 'image/hough_lines_full/test_invalid_parameters.py', []),
    ('phase_registration_errors', 'image/phase_registration/test_errors.py', []),
    ('seam_multiband_blend_errors', 'image/seam_multiband_blend/test_errors.py', []),
    ('seam_find_errors', 'image/seam_find/test_errors.py', []),
    ('multiband_blend_edges', 'image/multiband_blend/test_edges.py', []),
    ('lab_kmeans_quantizer_errors', 'image/lab_kmeans_quantizer/test_errors.py', []),
    ('homography_ransac_edges', 'image/homography_ransac/test_edges.py', []),
    ('hsv_roundtrip', 'integration/test_hsv_roundtrip.py', []),
    ('quant_roundtrip', 'dsp/jpeg_quant_zigzag/test_pipeline.py', []),
    ('jpeg_scan', 'integration/test_jpeg_scan.py', []),
    ('jpeg_grayscale_errors', 'dsp/jpeg_grayscale/test_errors.py', []),
    ('jpeg_color_scan_errors', 'dsp/jpeg_color_scan/test_errors.py', []),
    ('jpeg_color_frame_errors', 'dsp/jpeg_color_frame/test_errors.py', []),
    ('cube_export', '../../host/color_lut3d/export_cube.py', ['--self-test', '--check-ffmpeg']),
    ('input_stability_guard', 'integration/test_input_stability.py', []),
    ('fast_nms_brief', 'integration/test_fast_brief.py', []),
    ('fill_components', 'integration/test_fill_components.py', []),
    ('fill_moments', 'integration/test_fill_moments.py', []),
    ('fill_rle_moments', 'integration/test_fill_rle_moments.py', []),
    ('deinterlace_diffusion', 'integration/test_deinterlace_diffusion.py', []),
    ('fill_contours', 'integration/test_fill_contours.py', []),
    ('lens_sampler', 'integration/test_lens_sampler.py', []),
    ('ransac_stabilization', 'integration/test_ransac_stabilization.py', []),
)

# Read-only production dependency and mathematical coefficient fixture used
# by an imported color oracle. Freeze both with the tested chains.
INTEGRATION_INPUTS = ('image/geometry/rtl/img_geo_frame_sampler.v',
                      'image/cielab_color/coefficients.json')


def snapshot_files(paths):
    return {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(set(paths))}


def changed_files(snapshot):
    changed = []
    for name, digest in snapshot.items():
        try:
            current = hashlib.sha256(Path(name).read_bytes()).hexdigest()
        except OSError:
            changed.append(name)
        else:
            if current != digest:
                changed.append(name)
    return changed


def collect_inputs():
    source_list = PACKAGE/'rtl_extension_sources.f'
    tracked = [source_list, Path(__file__).resolve(), PACKAGE/'integration/tooling.py',
               PACKAGE/'integration/audit_checkpoint.py',
               PACKAGE/'integration/test_extension_batch.py',
               PACKAGE/'integration/test_extension_batch_guards.py']
    tracked.extend(ROOT/line.strip() for line in source_list.read_text(encoding='utf-8').splitlines()
                   if line.strip() and not line.lstrip().startswith('#'))
    for _, script, source in CASES:
        tracked.extend((PACKAGE/script, PACKAGE/source))
        # Include imported or companion testbench sources, not generated reports.
        tracked.extend(path for path in (PACKAGE/source).parent.rglob('*')
                       if path.is_file() and path.suffix in ('.py', '.v', '.sv', '.vh', '.hex', '.mem'))
    tracked.extend(PACKAGE/script for _, script, _ in INTEGRATIONS)
    tracked.extend(PACKAGE/name for name in INTEGRATION_INPUTS)
    return snapshot_files(tracked)


def main():
    folder = evidence_dir("image_extensions")
    snapshot = collect_inputs()
    write_json(folder/'tested_input_sha256.json', snapshot)
    (folder/'runner_snapshot.py').write_bytes(Path(__file__).resolve().read_bytes())
    (folder/'source_list_snapshot.f').write_bytes((PACKAGE/'rtl_extension_sources.f').read_bytes())
    results = []
    for name, script, source in CASES:
        entry = {"name": name, "source": source, "board_tested": False}
        try:
            path = PACKAGE / source
            before = hashlib.sha256(path.read_bytes()).hexdigest()
            execute([sys.executable, '-B', PACKAGE / script], ROOT, folder / f"{name}.log", timeout=600)
            after = hashlib.sha256(path.read_bytes()).hexdigest()
            if before != after:
                raise RuntimeError("source changed during regression")
            entry.update(status="PASS", rtl_sha256=after)
        except Exception as exc:
            entry.update(status="FAIL", error=str(exc))
        results.append(entry)
        print(f"{name}: {entry['status']}", flush=True)
    integrations = []
    for name, script, args in INTEGRATIONS:
        result = {'name': name, 'status': 'PASS'}
        try:
            execute([sys.executable, '-B', PACKAGE/script, *args], ROOT, folder/f'{name}.log', timeout=600)
        except Exception as exc:
            result.update(status='FAIL', error=str(exc))
        integrations.append(result)
        print(f"{name}: {result['status']}", flush=True)
    for entry in results:
        if entry['status'] == 'PASS':
            current = hashlib.sha256((PACKAGE / entry['source']).read_bytes()).hexdigest()
            if current != entry['rtl_sha256']:
                entry.update(status='FAIL', error='source changed after its regression')
    bundle = {'status': 'PASS'}
    try:
        execute(['iverilog', '-g2012', '-tnull', '-f', PACKAGE/'rtl_extension_sources.f'],
                ROOT, folder/'bundle_compile.log', timeout=120)
    except Exception as exc:
        bundle.update(status='FAIL', error=str(exc))
    final_snapshot = collect_inputs()
    changed = sorted(name for name in set(snapshot) | set(final_snapshot)
                     if snapshot.get(name) != final_snapshot.get(name))
    provenance = {'status': 'FAIL' if changed else 'PASS', 'changed_files': changed,
                  'tracked_file_count': len(snapshot), 'sha256_record': 'tested_input_sha256.json'}
    write_json(folder / "results.json", {"scope": "local functional simulation", "results": results,
                                         'integrations': integrations, 'source_bundle_compile': bundle,
                                         'input_stability': provenance})
    print(folder, flush=True)
    return int(provenance['status'] != 'PASS' or bundle['status'] != 'PASS' or
               any(item["status"] != "PASS" for item in results+integrations))


if __name__ == "__main__":
    raise SystemExit(main())

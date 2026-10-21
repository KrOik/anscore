# Functional IP index

按各 IP manifest 的功能族索引；验证状态仍以对应包文档为准。

## acquisition

- [calibration24](../cores/system/stream_bus_library/ip/calibration24)
- [frame_align4](../cores/system/stream_bus_library/ip/frame_align4)
- [timestamp64](../cores/system/stream_bus_library/ip/timestamp64)
- [trigger_window](../cores/system/stream_bus_library/ip/trigger_window)

## arith

- [bf16_mul](../cores/acceleration/operator_library/ip/bf16_mul)
- [cordic_atan](../cores/acceleration/operator_library/ip/cordic_atan)
- [csd_recode](../cores/acceleration/operator_library/ip/csd_recode)
- [div_nonrestoring](../cores/acceleration/operator_library/ip/div_nonrestoring)
- [fadd_s32](../cores/acceleration/operator_library/ip/fadd_s32)
- [fix2float](../cores/acceleration/operator_library/ip/fix2float)
- [float2fix_rne](../cores/acceleration/operator_library/ip/float2fix_rne)
- [gw2a_ips_booth_mult_s16](../cores/system/ip_series/ip/booth_mult_s16)
- [gw2a_ips_divider_s16](../cores/system/ip_series/ip/divider_s16)
- [gw2a_ips_dot_mac8](../cores/system/ip_series/ip/dot_mac8)
- [gw2a_ips_ewma_moving_avg](../cores/system/ip_series/ip/ewma_moving_avg)
- [gw2a_ips_fix_add_sat](../cores/system/ip_series/ip/fix_add_sat)
- [gw2a_ips_iir_biquad](../cores/system/ip_series/ip/iir_biquad)
- [gw2a_ips_isqrt_iter](../cores/system/ip_series/ip/isqrt_iter)
- [gw2a_ips_reciprocal_lut](../cores/system/ip_series/ip/reciprocal_lut)
- [isqrt](../cores/acceleration/operator_library/ip/isqrt)
- [mont_mul](../cores/acceleration/operator_library/ip/mont_mul)
- [nr_recip](../cores/acceleration/operator_library/ip/nr_recip)

## arithmetic

- [absdiff32](../cores/system/utility_library/ip/absdiff32)
- [clamp_signed32](../cores/system/utility_library/ip/clamp_signed32)
- [minmax_signed32](../cores/system/utility_library/ip/minmax_signed32)
- [round_shift_even32](../cores/system/utility_library/ip/round_shift_even32)
- [sadd_overflow32](../cores/system/utility_library/ip/sadd_overflow32)
- [ssub_overflow32](../cores/system/utility_library/ip/ssub_overflow32)
- [uadd_carry32](../cores/system/utility_library/ip/uadd_carry32)
- [usub_borrow32](../cores/system/utility_library/ip/usub_borrow32)

## audio

- [biquad_cascade_step](../cores/acceleration/operator_library/ip/biquad_cascade_step)
- [biquad_df1_s12](../cores/acceleration/operator_library/ip/biquad_df1_s12)
- [biquad_df2_s12](../cores/acceleration/operator_library/ip/biquad_df2_s12)
- [cic_comp_s12](../cores/acceleration/operator_library/ip/cic_comp_s12)
- [dsm2_mod](../cores/acceleration/operator_library/ip/dsm2_mod)
- [envelope_ar](../cores/acceleration/operator_library/ip/envelope_ar)
- [goertzel_dtmf](../cores/acceleration/operator_library/ip/goertzel_dtmf)
- [karplus_strong](../cores/acceleration/operator_library/ip/karplus_strong)
- [poly2_interp](../cores/acceleration/operator_library/ip/poly2_interp)
- [tdm8_demux](../cores/acceleration/operator_library/ip/tdm8_demux)

## bitops

- [bitfield_extract32](../cores/system/utility_library/ip/bitfield_extract32)
- [bitfield_insert32](../cores/system/utility_library/ip/bitfield_insert32)
- [bitreverse32](../cores/system/utility_library/ip/bitreverse32)
- [byte_reverse32](../cores/system/utility_library/ip/byte_reverse32)
- [clz32](../cores/system/utility_library/ip/clz32)
- [ctz32](../cores/system/utility_library/ip/ctz32)
- [popcount32](../cores/system/utility_library/ip/popcount32)
- [rotate32](../cores/system/utility_library/ip/rotate32)

## cdc

- [gw2a_ips_cdc_bus_gray](../cores/system/ip_series/ip/cdc_bus_gray)
- [gw2a_ips_cdc_handshake_2ff](../cores/system/ip_series/ip/cdc_handshake_2ff)
- [gw2a_ips_cdc_reset_bridge](../cores/system/ip_series/ip/cdc_reset_bridge)
- [gw2a_ips_cdc_toggle_sync](../cores/system/ip_series/ip/cdc_toggle_sync)

## coding

- [bcd8_decode](../cores/system/utility_library/ip/bcd8_decode)
- [bcd8_encode](../cores/system/utility_library/ip/bcd8_encode)
- [crc16_poly1021_byte](../cores/system/utility_library/ip/crc16_poly1021_byte)
- [crc8_poly07_byte](../cores/system/utility_library/ip/crc8_poly07_byte)
- [gray_decode32](../cores/system/utility_library/ip/gray_decode32)
- [hamming13_decode8](../cores/system/utility_library/ip/hamming13_decode8)
- [hamming13_encode8](../cores/system/utility_library/ip/hamming13_encode8)
- [thermometer_decode32](../cores/system/utility_library/ip/thermometer_decode32)

## comm

- [comm_crc32_frame](../cores/acceleration/operator_library/ip/comm_crc32_frame)
- [comm_nrzi_fmr32](../cores/acceleration/operator_library/ip/comm_nrzi_fmr32)
- [comm_pattern_lock32](../cores/acceleration/operator_library/ip/comm_pattern_lock32)
- [comm_polar_enc16](../cores/acceleration/operator_library/ip/comm_polar_enc16)
- [comm_qam16_llr](../cores/acceleration/operator_library/ip/comm_qam16_llr)
- [comm_viterbi_acs4](../cores/acceleration/operator_library/ip/comm_viterbi_acs4)

## control

- [atomic_config](../cores/system/stream_bus_library/ip/atomic_config)
- [axi_lite_interconnect](../cores/system/stream_bus_library/ip/axi_lite_interconnect)
- [bus_timeout_monitor](../cores/system/stream_bus_library/ip/bus_timeout_monitor)
- [ctl_credit_arb8](../cores/acceleration/operator_library/ip/ctl_credit_arb8)
- [ctl_phase_nco32](../cores/acceleration/operator_library/ip/ctl_phase_nco32)
- [ctl_pid_form_s16](../cores/acceleration/operator_library/ip/ctl_pid_form_s16)
- [ctl_quadrature_decoder](../cores/acceleration/operator_library/ip/ctl_quadrature_decoder)
- [ctl_slew_limiter_s16](../cores/acceleration/operator_library/ip/ctl_slew_limiter_s16)
- [ctl_watchdog_window32](../cores/acceleration/operator_library/ip/ctl_watchdog_window32)
- [debounce_word32](../cores/system/utility_library/ip/debounce_word32)
- [event_counter32](../cores/system/utility_library/ip/event_counter32)
- [first_fault32](../cores/system/utility_library/ip/first_fault32)
- [hysteresis32](../cores/system/utility_library/ip/hysteresis32)
- [register_snapshot](../cores/system/stream_bus_library/ip/register_snapshot)
- [round_robin8](../cores/system/utility_library/ip/round_robin8)
- [sticky_event32](../cores/system/utility_library/ip/sticky_event32)
- [token_bucket32](../cores/system/utility_library/ip/token_bucket32)
- [watermark32](../cores/system/utility_library/ip/watermark32)

## crypto

- [aes128_round](../cores/acceleration/operator_library/ip/aes128_round)
- [aes_key_schedule](../cores/acceleration/operator_library/ip/aes_key_schedule)
- [chacha20_quarterround](../cores/acceleration/operator_library/ip/chacha20_quarterround)
- [ghash_mul32](../cores/acceleration/operator_library/ip/ghash_mul32)
- [lfsr_galois_keystream](../cores/acceleration/operator_library/ip/lfsr_galois_keystream)
- [md5_round](../cores/acceleration/operator_library/ip/md5_round)
- [sha1_round](../cores/acceleration/operator_library/ip/sha1_round)
- [sha256_round](../cores/acceleration/operator_library/ip/sha256_round)
- [sm4_round](../cores/acceleration/operator_library/ip/sm4_round)
- [xtea_block](../cores/acceleration/operator_library/ip/xtea_block)

## ctrl

- [gw2a_ips_debounce_matrix](../cores/system/ip_series/ip/debounce_matrix)
- [gw2a_ips_gpio_irq_bank](../cores/system/ip_series/ip/gpio_irq_bank)
- [gw2a_ips_kbd_matrix_scan](../cores/system/ip_series/ip/kbd_matrix_scan)
- [gw2a_ips_rr_arbiter4](../cores/system/ip_series/ip/rr_arbiter4)
- [gw2a_ips_rtc_calendar](../cores/system/ip_series/ip/rtc_calendar)
- [gw2a_ips_timer4_pwm_cap](../cores/system/ip_series/ip/timer4_pwm_cap)

## diagnostics

- [change_detect32](../cores/system/utility_library/ip/change_detect32)
- [march_step32](../cores/system/utility_library/ip/march_step32)
- [onehot_guard32](../cores/system/utility_library/ip/onehot_guard32)
- [parity_lane32](../cores/system/utility_library/ip/parity_lane32)
- [range_guard32](../cores/system/utility_library/ip/range_guard32)
- [redundancy_compare32](../cores/system/utility_library/ip/redundancy_compare32)
- [stuck_fault32](../cores/system/utility_library/ip/stuck_fault32)
- [walking_pattern32](../cores/system/utility_library/ip/walking_pattern32)

## dsp

- [dsp_complex_mul_s12](../cores/acceleration/operator_library/ip/dsp_complex_mul_s12)
- [dsp_dot2_mac_s12](../cores/acceleration/operator_library/ip/dsp_dot2_mac_s12)
- [dsp_dot4_s12_pipe](../cores/acceleration/operator_library/ip/dsp_dot4_s12_pipe)
- [dsp_fir3_s12](../cores/acceleration/operator_library/ip/dsp_fir3_s12)
- [dsp_iir_lpf_s12](../cores/acceleration/operator_library/ip/dsp_iir_lpf_s12)
- [dsp_mac_s12](../cores/acceleration/operator_library/ip/dsp_mac_s12)
- [dsp_q12x2_round_sat](../cores/acceleration/operator_library/ip/dsp_q12x2_round_sat)

## fec

- [bch31_syndrome](../cores/acceleration/operator_library/ip/bch31_syndrome)
- [convk7_acs16](../cores/acceleration/operator_library/ip/convk7_acs16)
- [gf256_poly_eval](../cores/acceleration/operator_library/ip/gf256_poly_eval)
- [hamming74_correct](../cores/acceleration/operator_library/ip/hamming74_correct)
- [interleave_convex](../cores/acceleration/operator_library/ip/interleave_convex)
- [ldpc_cn_minsum](../cores/acceleration/operator_library/ip/ldpc_cn_minsum)
- [ldpc_vn_update](../cores/acceleration/operator_library/ip/ldpc_vn_update)
- [puncture_map_r13](../cores/acceleration/operator_library/ip/puncture_map_r13)
- [rs255_syndrome_acc](../cores/acceleration/operator_library/ip/rs255_syndrome_acc)
- [turbo_alpha_step](../cores/acceleration/operator_library/ip/turbo_alpha_step)

## fft

- [chirp_mult_s12](../cores/acceleration/operator_library/ip/chirp_mult_s12)
- [cmul_q15](../cores/acceleration/operator_library/ip/cmul_q15)
- [complex_add_sat](../cores/acceleration/operator_library/ip/complex_add_sat)
- [cordic_rotate](../cores/acceleration/operator_library/ip/cordic_rotate)
- [dit_stage_map](../cores/acceleration/operator_library/ip/dit_stage_map)
- [mag_approx_s12](../cores/acceleration/operator_library/ip/mag_approx_s12)
- [r2_bfly_s12](../cores/acceleration/operator_library/ip/r2_bfly_s12)
- [r4_bfly_s12](../cores/acceleration/operator_library/ip/r4_bfly_s12)
- [stockham_addr](../cores/acceleration/operator_library/ip/stockham_addr)
- [twiddle_index16](../cores/acceleration/operator_library/ip/twiddle_index16)

## iface

- [gw2a_ips_baud_detect_uart](../cores/system/ip_series/ip/baud_detect_uart)
- [gw2a_ips_i2c_slave_reg](../cores/system/ip_series/ip/i2c_slave_reg)
- [gw2a_ips_i2s_rx_slave](../cores/system/ip_series/ip/i2s_rx_slave)
- [gw2a_ips_i2s_tx_master](../cores/system/ip_series/ip/i2s_tx_master)
- [gw2a_ips_ir_nec_rx](../cores/system/ip_series/ip/ir_nec_rx)
- [gw2a_ips_mdio_master](../cores/system/ip_series/ip/mdio_master)
- [gw2a_ips_modbus_rtu_fsm](../cores/system/ip_series/ip/modbus_rtu_fsm)
- [gw2a_ips_one_wire_master](../cores/system/ip_series/ip/one_wire_master)
- [gw2a_ips_pdm_decim16](../cores/system/ip_series/ip/pdm_decim16)
- [gw2a_ips_spi_slave_reg](../cores/system/ip_series/ip/spi_slave_reg)

## image

- [img_bayer_dual_lane](../cores/acceleration/operator_library/ip/img_bayer_dual_lane)
- [img_box_blur_div3_u8x4](../cores/acceleration/operator_library/ip/img_box_blur_div3_u8x4)
- [img_dither_bayer4x4](../cores/acceleration/operator_library/ip/img_dither_bayer4x4)
- [img_gaussian5_edge_u8](../cores/acceleration/operator_library/ip/img_gaussian5_edge_u8)
- [img_histogram_bin16_update](../cores/acceleration/operator_library/ip/img_histogram_bin16_update)
- [img_median3_u8x4](../cores/acceleration/operator_library/ip/img_median3_u8x4)
- [img_sobel_mag_u8](../cores/acceleration/operator_library/ip/img_sobel_mag_u8)

## memprot

- [memprot_cache_tag_compare](../cores/acceleration/operator_library/ip/memprot_cache_tag_compare)
- [memprot_misr32_signature](../cores/acceleration/operator_library/ip/memprot_misr32_signature)
- [memprot_mpu_region_check](../cores/acceleration/operator_library/ip/memprot_mpu_region_check)
- [memprot_scrub_cursor_window](../cores/acceleration/operator_library/ip/memprot_scrub_cursor_window)
- [memprot_secded32_correct](../cores/acceleration/operator_library/ip/memprot_secded32_correct)
- [memprot_secded32_encode](../cores/acceleration/operator_library/ip/memprot_secded32_encode)

## memsys

- [addr_scramble](../cores/acceleration/operator_library/ip/addr_scramble)
- [afifo_gray](../cores/acceleration/operator_library/ip/afifo_gray)
- [bank_alloc](../cores/acceleration/operator_library/ip/bank_alloc)
- [cam_match](../cores/acceleration/operator_library/ip/cam_match)
- [ecc72_gen](../cores/acceleration/operator_library/ip/ecc72_gen)
- [fifo_wm](../cores/acceleration/operator_library/ip/fifo_wm)
- [lru8_victim](../cores/acceleration/operator_library/ip/lru8_victim)
- [march_engine](../cores/acceleration/operator_library/ip/march_engine)
- [raid5_pq](../cores/acceleration/operator_library/ip/raid5_pq)
- [tlb8_lookup](../cores/acceleration/operator_library/ip/tlb8_lookup)

## motor

- [backemf_obs_s12](../cores/acceleration/operator_library/ip/backemf_obs_s12)
- [clarke_s12](../cores/acceleration/operator_library/ip/clarke_s12)
- [cordic_sincos](../cores/acceleration/operator_library/ip/cordic_sincos)
- [inv_park_s12](../cores/acceleration/operator_library/ip/inv_park_s12)
- [ipi_pid_s12](../cores/acceleration/operator_library/ip/ipi_pid_s12)
- [mt_speed](../cores/acceleration/operator_library/ip/mt_speed)
- [park_s12](../cores/acceleration/operator_library/ip/park_s12)
- [pwm_deadband](../cores/acceleration/operator_library/ip/pwm_deadband)
- [sinc3_decim](../cores/acceleration/operator_library/ip/sinc3_decim)
- [svpwm_sector](../cores/acceleration/operator_library/ip/svpwm_sector)

## netio

- [bitmap_scan](../cores/acceleration/operator_library/ip/bitmap_scan)
- [bloom4_update](../cores/acceleration/operator_library/ip/bloom4_update)
- [countmin_update](../cores/acceleration/operator_library/ip/countmin_update)
- [hll_reg_update](../cores/acceleration/operator_library/ip/hll_reg_update)
- [ipv4_hdr_csum](../cores/acceleration/operator_library/ip/ipv4_hdr_csum)
- [lpm_trie_step](../cores/acceleration/operator_library/ip/lpm_trie_step)
- [pacing_wf2q](../cores/acceleration/operator_library/ip/pacing_wf2q)
- [qinq_walk](../cores/acceleration/operator_library/ip/qinq_walk)
- [radix_tree_step](../cores/acceleration/operator_library/ip/radix_tree_step)
- [toeplitz_rss](../cores/acceleration/operator_library/ip/toeplitz_rss)

## nn

- [gw2a_ips_bn_fold_lut](../cores/system/ip_series/ip/bn_fold_lut)
- [gw2a_ips_conv1d_depthwise](../cores/system/ip_series/ip/conv1d_depthwise)
- [gw2a_ips_int8_mac_array](../cores/system/ip_series/ip/int8_mac_array)
- [gw2a_ips_quant_int8_sym](../cores/system/ip_series/ip/quant_int8_sym)
- [gw2a_ips_softmax_fixed](../cores/system/ip_series/ip/softmax_fixed)
- [gw2a_ips_topk_argmax4](../cores/system/ip_series/ip/topk_argmax4)

## obs

- [gw2a_ips_err_log_sticky](../cores/system/ip_series/ip/err_log_sticky)
- [gw2a_ips_handoff_analyzer](../cores/system/ip_series/ip/handoff_analyzer)
- [gw2a_ips_perf_event_ctr](../cores/system/ip_series/ip/perf_event_ctr)

## package-specific

- [agc_stream](../cores/signal_processing/dsp_isp_library/dsp/agc)
- [basic_isp_top](../cores/signal_processing/dsp_isp_library/isp/basic_isp)
- [bayer_demosaic](../cores/signal_processing/dsp_isp_library/isp/bayer)
- [correlation_stream](../cores/signal_processing/dsp_isp_library/dsp/correlation)
- [dc_stream](../cores/signal_processing/dsp_isp_library/dsp/dc)
- [dc_stream](../cores/signal_processing/dsp_isp_library/dsp/dc/candidates/registered_output_v3/promotion)
- [dc_stream](../cores/signal_processing/dsp_isp_library/dsp/dc/legacy/latency1_3237f607)
- [ddcduc](../cores/signal_processing/dsp_isp_library/dsp/ddcduc)
- [dsp_isp_csc](../cores/signal_processing/dsp_isp_library/isp)
- [dsp_isp_median](../cores/signal_processing/dsp_isp_library/isp/median)
- [dsp_isp_scale_poly6](../cores/signal_processing/dsp_isp_library/isp/scale)
- [farrow_cubic_stream](../cores/signal_processing/dsp_isp_library/dsp/farrow)
- [fixedpoint_arithmetic](../cores/signal_processing/dsp_isp_library/infra/fixedpoint)
- [goertzel_bank](../cores/signal_processing/dsp_isp_library/dsp/goertzel)
- [gw2a_cnn_activation_lut](../cores/acceleration/cnn_systolic/ip/activation_lut)
- [gw2a_cnn_conv_layer](../cores/acceleration/cnn_systolic/ip/conv_layer)
- [gw2a_cnn_d_manager](../cores/acceleration/cnn_systolic/ip/d_manager)
- [gw2a_cnn_extrema_finder](../cores/acceleration/cnn_systolic/ip/extrema_finder)
- [gw2a_cnn_input_layer](../cores/acceleration/cnn_systolic/ip/input_layer)
- [gw2a_cnn_lprnet_post_process](../cores/acceleration/cnn_systolic/ip/lprnet_post_process)
- [gw2a_cnn_lprnet_spatial_sum](../cores/acceleration/cnn_systolic/ip/lprnet_spatial_sum)
- [gw2a_cnn_max_pool2d](../cores/acceleration/cnn_systolic/ip/max_pool2d)
- [gw2a_cnn_my_fifo](../cores/acceleration/cnn_systolic/ip/my_fifo)
- [gw2a_cnn_output_layer](../cores/acceleration/cnn_systolic/ip/output_layer)
- [gw2a_cnn_pe](../cores/acceleration/cnn_systolic/ip/pe)
- [gw2a_cnn_pe_col](../cores/acceleration/cnn_systolic/ip/pe_col)
- [gw2a_cnn_pe_page](../cores/acceleration/cnn_systolic/ip/pe_page)
- [gw2a_cnn_sdp_ram](../cores/acceleration/cnn_systolic/ip/sdp_ram)
- [gw2a_cnn_w_manager](../cores/acceleration/cnn_systolic/ip/w_manager)
- [gw2a_comm_axil_slave](../cores/communication/primitives/ip/axil_slave)
- [gw2a_comm_fifo_async](../cores/communication/primitives/ip/fifo_async)
- [gw2a_comm_i2c_master](../cores/communication/primitives/ip/i2c_master)
- [gw2a_comm_spi_master](../cores/communication/primitives/ip/spi_master)
- [gw2a_comm_uart_rx](../cores/communication/primitives/ip/uart_rx)
- [gw2a_comm_uart_tx](../cores/communication/primitives/ip/uart_tx)
- [gw2a_crypto_aes128](../cores/crypto/primitives/ip/aes128)
- [gw2a_crypto_crc](../cores/crypto/primitives/ip/crc)
- [gw2a_crypto_sha256](../cores/crypto/primitives/ip/sha256)
- [gw2a_dsp_cordic](../cores/signal_processing/dsp/ip/cordic)
- [gw2a_dsp_dds_nco](../cores/signal_processing/dsp/ip/dds_nco)
- [gw2a_dsp_fir16](../cores/signal_processing/dsp/ip/fir16)
- [gw2a_dsp_pid_core](../cores/signal_processing/dsp/ip/pid_core)
- [gw2a_img_gaussian3x3](../cores/image_processing/window/ip/gaussian3x3)
- [gw2a_img_median3x3](../cores/image_processing/window/ip/median3x3)
- [gw2a_img_morph3x3](../cores/image_processing/window/ip/morph3x3)
- [gw2a_img_sobel_edge](../cores/image_processing/window/ip/sobel_edge)
- [gw2a_img_threshold_bin](../cores/image_processing/window/ip/threshold_bin)
- [gw2a_img_win3x3_gen](../cores/image_processing/window/ip/win3x3_gen)
- [gw2a_sig_cic_dec8](../cores/signal_processing/transforms/ip/cic_dec8)
- [gw2a_sig_fft64](../cores/signal_processing/transforms/ip/fft64)
- [gw2a_sig_hist256](../cores/signal_processing/transforms/ip/hist256)
- [gw2a_sig_otsu_thresh](../cores/signal_processing/transforms/ip/otsu_thresh)
- [gw2a_w2_bg_model](../cores/system/extended_library/ip/bg_model)
- [gw2a_w2_bnn_conv3x3](../cores/system/extended_library/ip/bnn_conv3x3)
- [gw2a_w2_bnn_dense](../cores/system/extended_library/ip/bnn_dense)
- [gw2a_w2_can_ctrl](../cores/system/extended_library/ip/can_ctrl)
- [gw2a_w2_canny_dth](../cores/system/extended_library/ip/canny_dth)
- [gw2a_w2_canny_grad](../cores/system/extended_library/ip/canny_grad)
- [gw2a_w2_canny_hyst](../cores/system/extended_library/ip/canny_hyst)
- [gw2a_w2_canny_nms](../cores/system/extended_library/ip/canny_nms)
- [gw2a_w2_ccl_bbox](../cores/system/extended_library/ip/ccl_bbox)
- [gw2a_w2_crc32_eth](../cores/system/extended_library/ip/crc32_eth)
- [gw2a_w2_dma_sg](../cores/system/extended_library/ip/dma_sg)
- [gw2a_w2_eth_mac_mii](../cores/system/extended_library/ip/eth_mac_mii)
- [gw2a_w2_feat_fast](../cores/system/extended_library/ip/feat_fast)
- [gw2a_w2_feat_harris](../cores/system/extended_library/ip/feat_harris)
- [gw2a_w2_feat_hog](../cores/system/extended_library/ip/feat_hog)
- [gw2a_w2_feat_lbp](../cores/system/extended_library/ip/feat_lbp)
- [gw2a_w2_frame_diff](../cores/system/extended_library/ip/frame_diff)
- [gw2a_w2_hist_clahe](../cores/system/extended_library/ip/hist_clahe)
- [gw2a_w2_ila_core](../cores/system/extended_library/ip/ila_core)
- [gw2a_w2_img_crop](../cores/system/extended_library/ip/img_crop)
- [gw2a_w2_img_histogram](../cores/system/extended_library/ip/img_histogram)
- [gw2a_w2_img_integral](../cores/system/extended_library/ip/img_integral)
- [gw2a_w2_img_scaler](../cores/system/extended_library/ip/img_scaler)
- [gw2a_w2_isp_awb](../cores/system/extended_library/ip/isp_awb)
- [gw2a_w2_isp_csc](../cores/system/extended_library/ip/isp_csc)
- [gw2a_w2_isp_demosaic](../cores/system/extended_library/ip/isp_demosaic)
- [gw2a_w2_isp_dpc](../cores/system/extended_library/ip/isp_dpc)
- [gw2a_w2_isp_gamma](../cores/system/extended_library/ip/isp_gamma)
- [gw2a_w2_isp_rgb2gray](../cores/system/extended_library/ip/isp_rgb2gray)
- [gw2a_w2_lfsr_prng](../cores/system/extended_library/ip/lfsr_prng)
- [gw2a_w2_match_sad](../cores/system/extended_library/ip/match_sad)
- [gw2a_w2_meas_proj](../cores/system/extended_library/ip/meas_proj)
- [gw2a_w2_mem_bist](../cores/system/extended_library/ip/mem_bist)
- [gw2a_w2_mot_bbox](../cores/system/extended_library/ip/mot_bbox)
- [gw2a_w2_prbs31](../cores/system/extended_library/ip/prbs31)
- [gw2a_w2_pwm_gen](../cores/system/extended_library/ip/pwm_gen)
- [gw2a_w2_qei_dec](../cores/system/extended_library/ip/qei_dec)
- [gw2a_w2_step_drv](../cores/system/extended_library/ip/step_drv)
- [gw2a_w2_tmr_voter](../cores/system/extended_library/ip/tmr_voter)
- [gw2a_w2_wdt_win](../cores/system/extended_library/ip/wdt_win)
- [hilbert_core](../cores/signal_processing/dsp_isp_library/dsp/hilbert)
- [integral_stats](../cores/signal_processing/dsp_isp_library/isp/localstats)
- [ispstats_stream](../cores/signal_processing/dsp_isp_library/isp/ispstats)
- [lms_stream](../cores/signal_processing/dsp_isp_library/dsp/lms)
- [mean_narrow_3237f607](../cores/signal_processing/dsp_isp_library/dsp/dc/candidates/mean_narrow_3237f607)
- [pfb_stream](../cores/signal_processing/dsp_isp_library/dsp/pfb)
- [polyphase_resampler](../cores/signal_processing/dsp_isp_library/dsp/resampler)
- [recovery](../cores/signal_processing/dsp_isp_library/dsp/recovery)
- [spectrum_preprocess](../cores/signal_processing/dsp_isp_library/dsp/spectrum)
- [stft_welch](../cores/signal_processing/dsp_isp_library/dsp/stft)
- [stream_testsrc](../cores/signal_processing/dsp_isp_library/infra/testsrc)

## packet

- [address_boundary4k](../cores/system/utility_library/ip/address_boundary4k)
- [burst_split4k](../cores/system/utility_library/ip/burst_split4k)
- [byte_lane_merge4](../cores/system/utility_library/ip/byte_lane_merge4)
- [internet_checksum_word](../cores/system/utility_library/ip/internet_checksum_word)
- [keep_compact4](../cores/system/utility_library/ip/keep_compact4)
- [leb128_decode4](../cores/system/utility_library/ip/leb128_decode4)
- [leb128_encode28](../cores/system/utility_library/ip/leb128_encode28)
- [pkt_field_extract_variable](../cores/acceleration/operator_library/ip/pkt_field_extract_variable)
- [pkt_header_validate4](../cores/acceleration/operator_library/ip/pkt_header_validate4)
- [pkt_realign_unaligned32](../cores/acceleration/operator_library/ip/pkt_realign_unaligned32)
- [pkt_tcp_option_walk32](../cores/acceleration/operator_library/ip/pkt_tcp_option_walk32)
- [pkt_token_meter_color](../cores/acceleration/operator_library/ip/pkt_token_meter_color)
- [pkt_trtcm_coloring](../cores/acceleration/operator_library/ip/pkt_trtcm_coloring)
- [sequence_window32](../cores/system/utility_library/ip/sequence_window32)

## path

- [gw2a_ips_barrel_align](../cores/system/ip_series/ip/barrel_align)
- [gw2a_ips_delay_tap](../cores/system/ip_series/ip/delay_tap)
- [gw2a_ips_fifo_sync_fwft](../cores/system/ip_series/ip/fifo_sync_fwft)
- [gw2a_ips_ram_dp_1w2r](../cores/system/ip_series/ip/ram_dp_1w2r)
- [gw2a_ips_ram_sp_1p](../cores/system/ip_series/ip/ram_sp_1p)
- [gw2a_ips_scr_descrambler](../cores/system/ip_series/ip/scr_descrambler)
- [gw2a_ips_secded64_ecc](../cores/system/ip_series/ip/secded64_ecc)

## pkt

- [gw2a_ips_bit_packer](../cores/system/ip_series/ip/bit_packer)
- [gw2a_ips_frame_len_crc](../cores/system/ip_series/ip/frame_len_crc)
- [gw2a_ips_rle_codec](../cores/system/ip_series/ip/rle_codec)
- [gw2a_ips_sync_marker_stuffer](../cores/system/ip_series/ip/sync_marker_stuffer)

## sec

- [gw2a_ips_ct_compare](../cores/system/ip_series/ip/ct_compare)
- [gw2a_ips_key_slot_kmu](../cores/system/ip_series/ip/key_slot_kmu)
- [gw2a_ips_trng_vonng_cond](../cores/system/ip_series/ip/trng_vonng_cond)

## sensing

- [ca_correlator](../cores/acceleration/operator_library/ip/ca_correlator)
- [crc16_modbus](../cores/acceleration/operator_library/ip/crc16_modbus)
- [dmx512_frame](../cores/acceleration/operator_library/ip/dmx512_frame)
- [kalman1d](../cores/acceleration/operator_library/ip/kalman1d)
- [kalman2d_cv](../cores/acceleration/operator_library/ip/kalman2d_cv)
- [mahony_ahrs](../cores/acceleration/operator_library/ip/mahony_ahrs)
- [manchester_io](../cores/acceleration/operator_library/ip/manchester_io)
- [onewire_slot](../cores/acceleration/operator_library/ip/onewire_slot)
- [quadrature_jitter](../cores/acceleration/operator_library/ip/quadrature_jitter)
- [ws2812_serial](../cores/acceleration/operator_library/ip/ws2812_serial)

## simd

- [simd_i16x2_abs_sat](../cores/acceleration/operator_library/ip/simd_i16x2_abs_sat)
- [simd_i16x2_mul_q15_round](../cores/acceleration/operator_library/ip/simd_i16x2_mul_q15_round)
- [simd_i16x2_sar_rne](../cores/acceleration/operator_library/ip/simd_i16x2_sar_rne)
- [simd_u8x4_add_sat](../cores/acceleration/operator_library/ip/simd_u8x4_add_sat)
- [simd_u8x4_diff_sat_i8](../cores/acceleration/operator_library/ip/simd_u8x4_diff_sat_i8)
- [simd_u8x4_mad_round](../cores/acceleration/operator_library/ip/simd_u8x4_mad_round)

## stream

- [backpressure_isolator](../cores/system/stream_bus_library/ip/backpressure_isolator)
- [frame_switch4](../cores/system/stream_bus_library/ip/frame_switch4)
- [packet_async_fifo](../cores/system/stream_bus_library/ip/packet_async_fifo)
- [stream_credit32](../cores/system/utility_library/ip/stream_credit32)
- [stream_delta32](../cores/system/utility_library/ip/stream_delta32)
- [stream_prefix_sum32](../cores/system/utility_library/ip/stream_prefix_sum32)
- [stream_rising_edges32](../cores/system/utility_library/ip/stream_rising_edges32)
- [stream_running_max32](../cores/system/utility_library/ip/stream_running_max32)
- [stream_running_min32](../cores/system/utility_library/ip/stream_running_min32)
- [stream_sequence32](../cores/system/utility_library/ip/stream_sequence32)
- [stream_xor_acc32](../cores/system/utility_library/ip/stream_xor_acc32)
- [width_converter](../cores/system/stream_bus_library/ip/width_converter)

## table

- [tab_alaw_compand13](../cores/acceleration/operator_library/ip/tab_alaw_compand13)
- [tab_gamma_lut16](../cores/acceleration/operator_library/ip/tab_gamma_lut16)
- [tab_gf256_inv](../cores/acceleration/operator_library/ip/tab_gf256_inv)
- [tab_gf256_mul](../cores/acceleration/operator_library/ip/tab_gf256_mul)
- [tab_probe3_cuckoo](../cores/acceleration/operator_library/ip/tab_probe3_cuckoo)
- [tab_ulaw_compress8](../cores/acceleration/operator_library/ip/tab_ulaw_compress8)

## test

- [capture_replay](../cores/system/stream_bus_library/ip/capture_replay)
- [fault_injector](../cores/system/stream_bus_library/ip/fault_injector)
- [march_controller](../cores/system/stream_bus_library/ip/march_controller)
- [stream_metrics](../cores/system/stream_bus_library/ip/stream_metrics)

## video

- [bresenham_step](../cores/acceleration/operator_library/ip/bresenham_step)
- [chroma_key](../cores/acceleration/operator_library/ip/chroma_key)
- [de_timing](../cores/acceleration/operator_library/ip/de_timing)
- [lvds_scramble20](../cores/acceleration/operator_library/ip/lvds_scramble20)
- [osd_blend_u8](../cores/acceleration/operator_library/ip/osd_blend_u8)
- [rgb2yuv709](../cores/acceleration/operator_library/ip/rgb2yuv709)
- [sprite_blend](../cores/acceleration/operator_library/ip/sprite_blend)
- [yuv2rgb709](../cores/acceleration/operator_library/ip/yuv2rgb709)
- [yuv420_pack](../cores/acceleration/operator_library/ip/yuv420_pack)
- [yuv422_unpack](../cores/acceleration/operator_library/ip/yuv422_unpack)

# GW2A-18C validated CNN IP package

Source: `external/CNN_FPGA` rtl_pds, adapted for Tang Primer 20K.
Every IP below passed RTL sim (iverilog) and on-board UART digest validation on GW2A-LV18PG256C8/I7 (27 MHz, COM24 115200).
Evidence: `../doc/board_uart_m00ff.txt`, `../doc/board_uart_mff00.txt`,
`../doc/utilization_ab.txt`.

| IP | core | selftest unit | digest | board mask |
|---|---|---|---|---|
| `gw2a_cnn_pe` | `pe` | 0 (PE) / 1 (PED, USE_DSP_PE=yes) | B865EC67 | m00ff |
| `gw2a_cnn_pe_col` | `pe_col` | 6 (COL) | D149A670 | m00ff |
| `gw2a_cnn_pe_page` | `pe_page` | 7 (PAGE) | C5BAB594 | m00ff |
| `gw2a_cnn_d_manager` | `d_manager` | 2 (DM) | 783B6C25 | m00ff |
| `gw2a_cnn_w_manager` | `w_manager` | 3 (WM) | 6A9E1AC5 | m00ff |
| `gw2a_cnn_sdp_ram` | `sdp_ram` | 4 (RAM) | 2339D078 | m00ff |
| `gw2a_cnn_my_fifo` | `my_fifo` | 5 (FIFO) | D0C7C975 | m00ff |
| `gw2a_cnn_max_pool2d` | `max_pool2d` | 8 (POOL) | 35A02396 | mff00 |
| `gw2a_cnn_activation_lut` | `activation_lut` | 9 (ALUT) | 830A5F5F | mff00 |
| `gw2a_cnn_input_layer` | `input_layer` | 10 (IL) | 41C4C21F | mff00 |
| `gw2a_cnn_output_layer` | `output_layer` | 11 (OL) | 46E9E19D | mff00 |
| `gw2a_cnn_conv_layer` | `lprnet_layer_direct` | 12 (LAYR) | 9A9AEA61 | mff00 |
| `gw2a_cnn_extrema_finder` | `extrema_finder` | 13 (EXTR) | 931885AA | mff00 |
| `gw2a_cnn_lprnet_spatial_sum` | `lprnet_spatial_sum` | 14 (SSUM) | 77330EC1 | mff00 |
| `gw2a_cnn_lprnet_post_process` | `lprnet_post_process` | 15 (CTC) | ED74208A | mff00 |

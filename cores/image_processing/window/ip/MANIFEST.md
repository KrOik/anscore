# GW2A-18C validated imgwin IP package

Streaming image-processing kernels for Tang Primer 20K (GW2A-LV18PG256C8/I7, 27 MHz). Every IP passed RTL sim (iverilog, 3 UNIT_EN masks) and on-board UART digest validation.
Evidence: `../doc/board_uart_full.txt`, `../doc/VALIDATION_LOG.md`.

| IP | cores | selftest unit | digest |
|---|---|---|---|
| `gw2a_img_win3x3_gen` | `win3x3_gen+line_buf_ram` | 0 (WIN) | BD71944D |
| `gw2a_img_gaussian3x3` | `gaussian3x3+win3x3_gen+line_buf_ram` | 1 (GAUS) | 1C69D353 |
| `gw2a_img_sobel_edge` | `sobel_edge+win3x3_gen+line_buf_ram` | 2 (SOB) | E1762120 |
| `gw2a_img_median3x3` | `median3x3+win3x3_gen+line_buf_ram` | 3 (MED) | A3A98A3C |
| `gw2a_img_morph3x3` | `morph3x3+win3x3_gen+line_buf_ram` | 4 (MRP) | 3E86450A |
| `gw2a_img_threshold_bin` | `threshold_bin` | 5 (THR) | 9FFADFC0 |

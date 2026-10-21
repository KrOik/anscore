# gw2a_cnn_lprnet_post_process

Spatial sum + argmax + CTC decode chain (LPRNet head).
- Core: `lprnet_post_process` (`src/lprnet_post_process.v`)
- Validated: selftest unit(s) 15 (CTC), digest `ED74208A`, board bitstream `mff00`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| rst_n | in | 1 | - | active-low sync reset |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_input_1 | input | 1 | no | pulse before each row |
| data_input_valid | input | 1 | no | data beat valid |
| data_input | input | PE_COL_NUM*DATA_WIDTH | yes | signed samples |
| out_char | output | OCHW | no | decoded channel index |
| out_valid | output | 1 | no | decoded char valid |
| frame_start_out | output | 1 | no | 1 beat before out_valid |

## Parameters

| name | default |
|---|---|
| PE_COL_NUM | 2 |
| CYCLE_PERIOD_OUT | 2 |
| IMG_COL | 8 |
| IMG_ROW | 6 |
| DATA_WIDTH | 8 |
| ACC_WIDTH | 16 |
| CONV_POSITIVE | 1 |
| BLANK_CHAR | 3 |
| VALID_CHAR_NUM | 4 |
| OCHW | $clog2(CYCLE_PERIOD_OUT*PE_COL_NUM) |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

# gw2a_cnn_w_manager

Weight sequencer: cyclic BSRAM/LUT-ROM readout, [col][row] layout.
- Core: `w_manager` (`src/w_manager.v`)
- Validated: selftest unit(s) 3 (WM), digest `6A9E1AC5`, board bitstream `m00ff`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_1 | input | 1 | no | restart weight sequence |
| W_out | output | PE_ROW_NUM*PE_COL_NUM*WEIGHT_WIDTH | yes | weight matrix, [col][row] order |

## Parameters

| name | default |
|---|---|
| PE_ROW_NUM | 9 |
| PE_COL_NUM | 2 |
| WEIGHT_WIDTH | 8 |
| CYCLE_PERIOD | 2 |
| WEIGHT_FILE | "wm_test.mem" |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

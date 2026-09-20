# gw2a_cnn_extrema_finder

Per-frame argmax/argmin over PE_COL_NUM x CYCLE_PERIOD_OUT channels.
- Core: `extrema_finder` (`src/extrema_finder.v`)
- Validated: selftest unit(s) 13 (EXTR), digest `931885AA`, board bitstream `mff00`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| rst_n | in | 1 | - | active-low sync reset |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| data_input_valid | input | 1 | no | data beat valid |
| new_line_1 | input | 1 | no | reset cycle counter per row |
| data_in | input | PE_COL_NUM*DATA_WIDTH | yes | signed samples |
| val_out | output | DATA_WIDTH | yes | extremum value |
| val_out_channel | output | CHW | no | winning channel index |
| val_valid | output | 1 | no | result valid |

## Parameters

| name | default |
|---|---|
| DATA_WIDTH | 8 |
| PE_COL_NUM | 2 |
| CYCLE_PERIOD_OUT | 2 |
| CONV_POSITIVE | 1 |
| CHW | $clog2(CYCLE_PERIOD_OUT*PE_COL_NUM) |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

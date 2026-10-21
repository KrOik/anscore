# gw2a_cnn_conv_layer

Full conv layer: input_layer + pe_page array + output_layer, streaming in/out.
- Core: `lprnet_layer_direct` (`src/layer.v`)
- Validated: selftest unit(s) 12 (LAYR), digest `9A9AEA61`, board bitstream `mff00`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| rst_n | in | 1 | - | active-low sync reset |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_input_1 | input | 1 | no | pulse before each input row |
| data_input_valid | input | 1 | no | pixel beat valid |
| data_input | input | PE_PAGE_NUM*DATA_WIDTH | no | input lanes |
| y_out | output | PE_COL_NUM*OUT_WIDTH | no | conv result |
| new_line_out_1 | output | 1 | no | row marker |
| output_valid | output | 1 | no | result valid |

## Parameters

| name | default |
|---|---|
| PE_PAGE_NUM | 2 |
| PE_ROW_NUM | 9 |
| KERNEL_COL | 3 |
| KERNEL_ROW | 3 |
| PE_COL_NUM | 2 |
| MAX_POOL | 0 |
| WITH_RELU | 1 |
| DATA_WIDTH | 8 |
| WEIGHT_WIDTH | 9 |
| CYCLE_PERIOD_OUT | 2 |
| CYCLE_PERIOD_IN | 1 |
| IMG_COL | 8 |
| IMG_ROW | 6 |
| STEP_ROW | 1 |
| STEP_COL | 1 |
| USE_DSP_PE | "no" |
| SHIFT_KEY | 4 |
| BIAS_WIDTH | 16 |
| OUT_WIDTH | 8 |
| WEIGHT_FILE0 | "pepage_weight.mem" |
| WEIGHT_FILE1 | "pepage_weight.mem" |
| WEIGHT_FILE2 | "pepage_weight.mem" |
| WEIGHT_FILE3 | "pepage_weight.mem" |
| BIAS_FILE | "bias_test.mem" |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

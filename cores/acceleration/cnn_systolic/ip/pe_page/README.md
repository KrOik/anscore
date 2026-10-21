# gw2a_cnn_pe_page

Output-channel-parallel page: PE_COL_NUM pe_col + weight ROM cycling.
- Core: `pe_page` (`src/pe_page.v`)
- Validated: selftest unit(s) 7 (PAGE), digest `C5BAB594`, board bitstream `m00ff`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_1 | input | 1 | no | row-start pulse, 1 beat before first data |
| data | input | PE_ROW_NUM*DATA_WIDTH | no | one input row beat |
| y_out | output | PE_COL_NUM*OUTPUT_WIDTH | yes | per-column results |

## Parameters

| name | default |
|---|---|
| PE_ROW_NUM | 9 |
| PE_COL_NUM | 2 |
| DATA_WIDTH | 7 |
| WEIGHT_WIDTH | 8 |
| CYCLE_PERIOD | 2 |
| OUTPUT_WIDTH | DATA_WIDTH + WEIGHT_WIDTH + $clog2(PE_ROW_NUM+1) |
| USE_DSP_PE | "no" |
| WEIGHT_FILE | "pepage_weight.mem" |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

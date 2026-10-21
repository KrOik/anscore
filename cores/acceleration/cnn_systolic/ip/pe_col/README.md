# gw2a_cnn_pe_col

Kernel-unrolled MAC chain: PE_ROW_NUM cascaded pe elements.
- Core: `pe_col` (`src/pe_col.v`)
- Validated: selftest unit(s) 6 (COL), digest `D149A670`, board bitstream `m00ff`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| D | input | PE_ROW_NUM*DATA_WIDTH | no | unrolled kernel data |
| W | input | PE_ROW_NUM*WEIGHT_WIDTH | yes | unrolled kernel weights |
| y_out | output | OUTPUT_WIDTH | yes | dot-product result |

## Parameters

| name | default |
|---|---|
| PE_ROW_NUM | 9 |
| DATA_WIDTH | 7 |
| WEIGHT_WIDTH | 8 |
| OUTPUT_WIDTH | DATA_WIDTH + WEIGHT_WIDTH + $clog2(PE_ROW_NUM+1) |
| USE_DSP_PE | "no" |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

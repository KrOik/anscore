# gw2a_cnn_d_manager

Data skew/deskew manager: per-row staggered delay lines.
- Core: `d_manager` (`src/d_manager.v`)
- Validated: selftest unit(s) 2 (DM), digest `783B6C25`, board bitstream `m00ff`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| data | input | PE_ROW_NUM*DATA_WIDTH | no | input stream |
| D | output | PE_ROW_NUM*DATA_WIDTH | no | aligned output stream |

## Parameters

| name | default |
|---|---|
| PE_ROW_NUM | 9 |
| DATA_WIDTH | 7 |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

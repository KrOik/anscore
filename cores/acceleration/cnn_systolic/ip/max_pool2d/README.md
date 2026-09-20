# gw2a_cnn_max_pool2d

Unsigned maximum over PE_ROW_NUM lanes, with two enabled pipeline stages.
- Core: `max_pool2d` (`src/max_pool2d.v`)
- Validated: selftest unit(s) 8 (POOL), digest `35A02396`, board bitstream `mff00`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| rst_n | in | 1 | - | active-low asynchronous reset |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_1 | input | 1 | no | row-start pulse |
| input_valid | input | 1 | no | data beat valid |
| data | input | PE_ROW_NUM*DATA_WIDTH | no | page row data |
| y_out | output | DATA_WIDTH | no | pooled result |
| new_line_out_1 | output | 1 | no | delayed row marker |
| output_valid | output | 1 | no | result valid |

## Parameters

| name | default |
|---|---|
| PE_ROW_NUM | 9 |
| DATA_WIDTH | 7 |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

Fresh functional audit (2026-09-24): 10 lane/width combinations PASS, 2000
cycles each. Covers each lane as the unique maximum, ties, zeros, unsigned
maximum values, random input-valid bubbles, clk_en stalls, row markers and
reset recovery. Values, valid and row marker all hold when clk_en is low.
Run `./scripts/test_cnn_max_pool.ps1 -OutputDir artifacts/pool_audit_new`
from the repository root, using a fresh directory. Evidence:
`artifacts/ip_optimization_20260924/cnn_pool_audit/`.
RTL unchanged; no new synthesis or physical validation in this audit.

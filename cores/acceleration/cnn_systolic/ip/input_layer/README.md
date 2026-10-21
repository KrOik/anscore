# gw2a_cnn_input_layer

Ping-pong line buffers + pixel window assembler; emits KERNEL_ROW x KERNEL_COL sliding windows.
- Core: `input_layer` (`src/input_layer.v`)
- Validated: selftest unit(s) 10 (IL), digest `41C4C21F`, board bitstream `mff00`

## Input cadence audit (2026-09-24)

For the packaged CPI=1/CPO=2, stride-1 configuration, an independent
coordinate-based simulation passes continuous input, whole-pipeline clk_en
pauses and one invalid cycle between input pixels. Two invalid cycles between
pixels fail (518/720 output bytes), despite all 48 pixels being accepted
without violating line_buf_full. Arbitrary data_input_valid gaps are therefore
not currently supported by the verified behavior. This is an open rate-boundary
issue, not an accepted repair. The historical IL digest remains unchanged.

Reproduce with `./scripts/audit_cnn_input_stream.ps1 -OutputDir artifacts/input_audit_new`
from the repository root; use a fresh directory. It returns a nonzero status
for the known failure. Evidence is under
`artifacts/ip_optimization_20260924/cnn_input_audit/confirmed/`.
The oracle covers the existing 40-window stream and does not claim a final-row
flush or complete-frame interface. No new physical validation was performed.

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| rst_n | in | 1 | - | active-low sync reset |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_input_1 | input | 1 | no | pulse before each input row |
| data_input_valid | input | 1 | no | pixel beat valid |
| data_input | input | PE_PAGE_NUM*DATA_WIDTH | no | page lanes per beat |
| data_out | output | PE_PAGE_NUM*PE_ROW_NUM*DATA_WIDTH | no | conv window, [row][page] |
| line_buf_full | output | 1 | no | line buffer backpressure |
| data_out_valid | output | 1 | no | window valid |
| new_line_out_1 | output | 1 | no | window row marker |

## Parameters

| name | default |
|---|---|
| DATA_WIDTH | 8 |
| PE_PAGE_NUM | 2 |
| PE_ROW_NUM | 9 |
| CYCLE_PERIOD_IN | 1 |
| CYCLE_PERIOD_OUT | 2 |
| STEP_ROW | 1 |
| STEP_COL | 1 |
| KERNEL_ROW | 3 |
| KERNEL_COL | 3 |
| IMG_COL | 8 |
| IMG_ROW | 6 |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

# gw2a_cnn_lprnet_spatial_sum

Signed accumulation across image rows for each column/channel position (LPRNet head stage).
- Core: `lprnet_spatial_sum` (`src/lprnet_spatial_sum.v`)
- Validated: selftest unit(s) 14 (SSUM), digest `77330EC1`, board bitstream `mff00`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| rst_n | in | 1 | - | active-low asynchronous reset |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_input_1 | input | 1 | no | pulse before each row |
| data_input_valid | input | 1 | no | data beat valid |
| data_input | input | PE_COL_NUM*DATA_WIDTH | yes | signed samples |
| y_out | output | PE_COL_NUM*ACC_WIDTH | yes | row sums |
| new_line_out_1 | output | 1 | no | row marker |
| output_valid | output | 1 | no | result valid |

## Parameters

| name | default |
|---|---|
| PE_COL_NUM | 2 |
| CYCLE_PERIOD_OUT | 2 |
| IMG_COL | 8 |
| IMG_ROW | 6 |
| DATA_WIDTH | 8 |
| ACC_WIDTH | 16 |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

## Short-row forwarding and verification (2026-09-25)

Depths `CYCLE_PERIOD_OUT*IMG_COL` 1 and 2 now forward pending writeback values
and explicitly captured RAM read/write collisions. First-row zeroing has
priority. The coefficient/accumulation storage remains synchronous RAM;
depths >=3 keep the existing datapath. A row marker must precede the first
valid sample by an enabled cycle. Valid inputs advance the column position;
clk_en=0 freezes the pipeline. Output latency remains three enabled edges
after acceptance, with the row marker one enabled edge before the first sum.
Arithmetic wraps to ACC_WIDTH; it does not saturate.

`scripts/test_cnn_spatial_sum.ps1 -OutputDir <new-directory>` passes 48
configurations over depths 1/2/3/4/8/16, rows 1/2/3/5, lanes 1/2/3,
widths 1/8/13 and accumulator widths 4/8/10/16, continuous/gapped inputs,
enable stalls, exact valid/marker timing, and three interrupted-frame resets.
The four row/lane/width tuples are selected cases, not their Cartesian product.
The full original CNN selftest and 544-byte UART regression also pass.

Board raw-result baseline reproduces the short-row error (212 identical
frames); fixed and reprogrammed images pass 213 and 212 frames, respectively,
checking 10,200 signed results at 27 MHz. The legacy SSUM digest 77330EC1
passes two complete board reports. Evidence and source snapshots:
`artifacts/ip_optimization_20260925/spatial_sum_fix/`.

With two lanes, isolated LUT1-4 counts change 137->171 at depth 1 and
103->169 at depth 2; depth 8 remains 108. Each retains two BRAM and zero DSP.
The combined depth-1/2 board harness changes 1276->1368 routed LUT4,
909->912 FF, with four BRAM and zero DSP; both meet 27 MHz. This is a
correctness repair with an area cost for short rows, not an area optimization.

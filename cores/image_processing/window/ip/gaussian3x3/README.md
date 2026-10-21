# gw2a_img_gaussian3x3

3x3 Gaussian blur (1/16)*[[1,2,1],[2,4,2],[1,2,1]], shift-add only. Wraps win3x3_gen + gaussian3x3.

- Cores: `gaussian3x3, win3x3_gen, line_buf_ram` (`src/gaussian3x3.v, src/win3x3_gen.v, src/line_buf_ram.v`)
- Validated: selftest unit 1 (GAUS), golden digest `1C69D353` (16x16 formula image, FNV-1a)
- Board evidence: `../../doc/board_uart_full.txt`
- Simulation: include `../../sim/gowin_bsram_sim.v` in iverilog compiles (line_buf_ram instantiates the Gowin DPX9B primitive directly; the file provides its behavioral model).

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low async reset |
| clk_en | in | 1 | step enable; tie 1 for full rate |
| pix | input | 8 | gray pixel in |
| pix_valid | input | 1 | pixel beat valid |
| new_line | input | 1 | 1-beat pulse before each input row |
| pix_out | output | 8 | blurred pixel out |
| out_valid | output | 1 | output valid |
| new_line_out | output | 1 | first pixel of output row |
| done | output | 1 | frame flush complete |

## Parameters

| name | default | note |
|---|---|---|
| IMG_W | 16 |  |
| IMG_H | 16 |  |

## Stream protocol

input rows: dedicated 1-beat new_line then IMG_W pix_valid beats; output: IMG_H x IMG_W results in row-major order, out_valid per beat, new_line_out on first result of each row. All sequential logic gated by clk_en (tie 1 for full-rate operation).

## Border policy

edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)][clamp(x+c-1,0,W-1)]; identical in tools/golden_model.py

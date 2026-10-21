# gw2a_img_threshold_bin

Fixed-threshold binarizer: pix>=THRESH -> 8'hFF else 8'h00. Passes the pixel-stream protocol through with 1-beat latency.

- Cores: `threshold_bin` (`src/threshold_bin.v`)
- Validated: selftest unit 5 (THR), golden digest `9FFADFC0` (16x16 formula image, FNV-1a)
- Board evidence: `../../doc/board_uart_full.txt`

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low async reset |
| clk_en | in | 1 | step enable; tie 1 for full rate |
| pix | input | 8 | gray pixel in |
| pix_valid | input | 1 | pixel beat valid |
| new_line | input | 1 | row-start pulse (passed through) |
| pix_out | output | 8 | 8'hFF/8'h00 out |
| out_valid | output | 1 | output valid |
| new_line_out | output | 1 | delayed row marker |

## Parameters

| name | default | note |
|---|---|---|
| THRESH | 8'd128 | binarization threshold |

## Stream protocol

input rows: dedicated 1-beat new_line then IMG_W pix_valid beats; output: IMG_H x IMG_W results in row-major order, out_valid per beat, new_line_out on first result of each row. All sequential logic gated by clk_en (tie 1 for full-rate operation).

## Border policy

edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)][clamp(x+c-1,0,W-1)]; identical in tools/golden_model.py

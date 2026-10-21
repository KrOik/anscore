# gw2a_cnn_pe

Single MAC pipeline element: y_out <= D*W + y_in (2-stage).
- Core: `pe` (`src/pe.v`)
- Validated: selftest unit(s) 0 (PE) / 1 (PED, USE_DSP_PE=yes), digest `B865EC67`, board bitstream `m00ff`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| D | input | DATA_WIDTH | no | unsigned pixel data |
| W | input | WEIGHT_WIDTH | yes | signed weight |
| y_in | input | ADDER2_WIDTH | yes | signed chain input |
| y_out | output | OUTPUT_WIDTH | yes | signed chain output, latency 2 |

## Parameters

| name | default |
|---|---|
| DATA_WIDTH | 7 |
| WEIGHT_WIDTH | 8 |
| ADDER2_WIDTH | 18 |
| OUTPUT_WIDTH | 19 |
| USE_DSP_PE | "no" |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

# gw2a_cnn_sdp_ram

Simple dual-port RAM, sync write + sync read (ram_style=block).
- Core: `sdp_ram` (`src/sdp_ram.v`)
- Validated: selftest unit(s) 4 (RAM), digest `2339D078`, board bitstream `m00ff`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| we | input | 1 | no | write enable (needs clk_en) |
| waddr | input | AW | no | write address |
| wdata | input | WIDTH | no | write data |
| re | input | 1 | no | read enable (needs clk_en) |
| raddr | input | AW | no | read address |
| q | output | WIDTH | no | registered read data |

## Parameters

| name | default |
|---|---|
| WIDTH | 21 |
| DEPTH | 128 |
| AW | (DEPTH > 1) ? $clog2(DEPTH) : 1 |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

# gw2a_cnn_my_fifo

Async-clock FIFO with Gray-code pointers (rd_clk/wr_clk domains).
- Core: `my_fifo` (`src/my_fifo.v`)
- Validated: selftest unit(s) 5 (FIFO), digest `D0C7C975`, board bitstream `m00ff`

## Asynchronous validation scope

The original unit-5 selftest uses the same clock on both ports. Its board
digest does not establish asynchronous CDC safety.

Run `./scripts/test_cnn_fifo_async.ps1 -OutputDir artifacts/fifo_async_new`
from the repository root with a fresh output directory. The 2026-09-24 run
passed all 12 depth/clock combinations: depths 2, 4, 16, 64 and write/read
periods 14/22, 22/14, 14/16 ns. It checks queue order, full/empty boundaries,
wraparound, random traffic and reset recovery. Evidence:
`artifacts/ip_optimization_20260924/cnn_fifo_audit/clock_matrix/`.

RTL simulation does not model metastability. Source Gray codes are currently
combinational conversions of binary pointer registers; source registration,
synchronizer placement/skew constraints and reset release need a separate CDC
review. No FIFO RTL optimization or asynchronous board validation is claimed.
Tested depths are powers of two, at least two. Read data while empty is not
checked as valid payload.

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| rd_clk / wr_clk | in | 1 | - | async FIFO clocks |
| rst | in | 1 | - | **active-high** async reset |
| rst | input | 1 | no | async reset, ACTIVE HIGH |
| wr_en | input | 1 | no | write enable |
| din | input | DATA_WIDTH | no | write data |
| rd_en | input | 1 | no | read enable |
| dout | output | DATA_WIDTH | no | read data |
| full | output | 1 | no | wr domain |
| empty | output | 1 | no | rd domain |

## Parameters

| name | default |
|---|---|
| DATA_WIDTH | 8 |
| FIFO_DEPTH | 16 |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

# gw2a_comm_fifo_async

Dual-clock FIFO, depth `2**AW`: Gray-coded read/write pointers, two-flop
pointer synchronizers in both directions, registered `dout` (read data valid
one `rd_clk` after `rd_en`).

- Core: `fifo_async` (`src/fifo_async.v`)
- Validated: selftest unit 4 (FIFO), clk -> clk/2 (BUFG) crossing, digest `B5FC9B84`
- Board evidence: `doc/board_uart_*.txt` (COMM5 report on pin M11, COM24)

## Ports

| port | dir | width | note |
|---|---|---|---|
| wr_clk | in | 1 | write clock |
| wr_rst_n | in | 1 | write-domain async reset |
| wr_en | in | 1 | write strobe (accepted when !full) |
| din | in | DW | write data |
| full | out | 1 | write side full |
| rd_clk | in | 1 | read clock |
| rd_rst_n | in | 1 | read-domain async reset |
| rd_en | in | 1 | read strobe (pops when !empty) |
| dout | out | DW | read data, 1 rd_clk after rd_en |
| empty | out | 1 | read side empty |

## Parameters

| name | default |
|---|---|
| DW | 8 |
| AW | 4 |

## Notes

- full/empty compare the *current* Gray pointers (no combinational loop
  through the next-pointer logic); `full` asserts exactly when the FIFO fills.
- Derived clocks (e.g. clk/2 toggled in fabric) must go through a BUFG before
  driving `rd_clk`/`wr_clk`; see `comm_selftest.v` unit 4 for the pattern.
- Memory maps to distributed RAM (2x RAM16SDP4 at DW=8, AW=4).

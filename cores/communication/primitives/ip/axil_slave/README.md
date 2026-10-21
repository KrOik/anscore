# gw2a_comm_axil_slave

AXI4-Lite slave: 16x32-bit register bank at 0x00..0x3C, full ready/valid
handshakes on AW/W/B/AR/R, byte write-strobes, SLVERR on out-of-range or
unaligned addresses.

- Core: `axil_slave` (`src/axil_slave.v`)
- Validated: selftest unit 3 (AXIL) master stimulus, digest `9B3A6985`
- Board evidence: `doc/board_uart_*.txt` (COMM5 report on pin M11, COM24)

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low reset |
| clk_en | in | 1 | step enable; tie 1 for full rate |
| awvalid | in | 1 | write address valid |
| awready | out | 1 | write address ready |
| awaddr | in | 8 | write address |
| wvalid | in | 1 | write data valid |
| wready | out | 1 | write data ready |
| wdata | in | 32 | write data |
| wstrb | in | 4 | byte strobes |
| bvalid | out | 1 | write response valid |
| bready | in | 1 | write response ready |
| bresp | out | 2 | 0=OKAY 2=SLVERR |
| arvalid | in | 1 | read address valid |
| arready | out | 1 | read address ready |
| araddr | in | 8 | read address |
| rvalid | out | 1 | read data valid |
| rready | in | 1 | read data ready |
| rdata | out | 32 | read data |
| rresp | out | 2 | 0=OKAY 2=SLVERR |

## Parameters

None.

## Notes

- AW and W channels are accepted independently; B issues after both.
- Addresses 0x00..0x3C, word-aligned only; everything else -> SLVERR.
- Registers reset to 0; wstrb performs per-byte read-modify-write.

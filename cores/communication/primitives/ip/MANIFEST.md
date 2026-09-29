# GW2A-18C validated bus/protocol IP package

Source: `cores/communication/primitives` (original work, Sipeed Tang Primer 20K dev kit).
Every IP below passed RTL sim (iverilog, independent Python golden digests),
full-mask + split-mask selftest, OSS synthesis/P&R/bitstream, and on-board
execution on GW2A-LV18PG256C8/I7 at 27 MHz.

Board evidence: `../doc/board_uart_*.txt` — the board's real COMM5 UART
report captured on COM24 (115200 8N1, pin M11).

| IP | core | selftest unit | digest | standalone resources |
|---|---|---|---|---|
| `gw2a_comm_uart_rx` | `uart_rx` | 0 (URX) | 6BC47DCE | 53 LUT, 11 ALU, 38 DFF, 0 DSP |
| `gw2a_comm_uart_tx` | `uart_tx` | report path | report bytes vs `sim/expected_report.mem` | 37 LUT, 11 ALU, 22 DFF, 0 DSP |
| `gw2a_comm_spi_master` | `spi_master` | 1 (SPIM) | E4107F07 | 263 LUT, 18 ALU, 119 DFF, 0 DSP |
| `gw2a_comm_i2c_master` | `i2c_master` | 2 (I2CM) | D6A89792 | 149 LUT, 20 ALU, 72 DFF, 0 DSP |
| `gw2a_comm_axil_slave` | `axil_slave` | 3 (AXIL) | 9B3A6985 | 517 LUT, 0 ALU, 597 DFF, 0 DSP |
| `gw2a_comm_fifo_async` | `fifo_async` | 4 (FIFO) | B5FC9B84 | 18 LUT, 10 ALU, 46 DFF, 2x RAM16SDP4, 0 DSP |

LUT_class = LUT1+LUT2+LUT3+LUT4+MUX2_LUT5 cells from `synth_gowin` stat.

Each `ip/<name>/` directory contains:

- `gw2a_comm_<name>.v` — thin wrapper instantiating the core (stable ports).
- `ip_manifest.json` — parameters, ports, clk/reset protocol, golden digest,
  board evidence, standalone synth resources.
- `README.md` — port table, parameter table, integration notes.

Per-IP independent verification (run from `cores/communication/primitives/`):

```bash
iverilog -g2012 -o build_oss/ip/gw2a_comm_<name>.vvp \
  ip/<name>/gw2a_comm_<name>.v src/<core>.v

yosys -p "read_verilog -sv ip/<name>/gw2a_comm_<name>.v src/<core>.v; \
  synth_gowin -family gw2a -top gw2a_comm_<name>"
```

Notes:

- `uart_rx`, `spi_master`, `i2c_master`, `axil_slave` follow the repo
  `clk_en` convention (tie `clk_en=1` for full rate). `uart_tx` has no
  `clk_en` port (verbatim template reuse). `fifo_async` is dual-clock.
- `i2c_master` uses open-drain SDA/SCL: wire `sda_oe`/`scl_oe` to open-drain
  pad drivers (drive low when oe=1, Hi-Z otherwise) with external pull-ups.
- `fifo_async` read/write clocks must be real clock nets; a fabric-derived
  clock needs a BUFG (see `comm_selftest.v` unit 4 pattern).

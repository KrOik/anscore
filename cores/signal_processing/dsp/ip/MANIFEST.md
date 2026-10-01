# GW2A-18C validated DSP IP package

Source: `cores/signal_processing/dsp` (original work, Sipeed Tang Primer 20K dev kit).
Every IP below passed RTL sim (iverilog, independent Python golden digests),
full-mask + split-mask selftest, OSS synthesis/P&R/bitstream, and on-board
execution on GW2A-LV18PG256C8/I7 at 27 MHz.

Board evidence: `../doc/board_uart_la.txt` — the board's real UART report
frames were decoded from FPGA pin A11 via the calibrated onboard fx2lafw
logic analyzer (host COM24/FTDI channel-B path returned zero bytes even for a
previously board-validated bitstream; see `../doc/VALIDATION_LOG.md`).

| IP | core | selftest unit(s) | digest | standalone resources |
|---|---|---|---|---|
| `gw2a_dsp_cordic` | `cordic` | 0 (CRDR) / 1 (CRDV) | 5B8CCF9D / 4A4E2D09 | 2197 LUT1-4, 350 wide mux cells, 1002 DFF, 0 DSP (-noalu, 2026-09-24) |
| `gw2a_dsp_dds_nco` | `dds_nco` | 2 (DDS) | 0F185BED | 2 LUT, 32 ALU, 32 DFF, 1 BSRAM, 0 DSP |
| `gw2a_dsp_fir16` | `fir16` | 3 (FIR) | 20038C18 | 132 LUT, 90 ALU, 137 DFF, 0 DSP |
| `gw2a_dsp_pid_core` | `pid_core` | 4 (PID) | 5C690862 | 172 LUT, 220 ALU, 49 DFF, 0 DSP |

CORDIC current optimization/board evidence is under repository
`artifacts/ip_optimization_20260924/cordic/`; see `cordic/README.md` for
the area/timing tradeoff. Older evidence and other IP resource figures remain
historical; different synthesis options are not directly comparable.

Each `ip/<name>/` directory contains:

- `gw2a_dsp_<name>.v` — thin wrapper instantiating the core (stable ports).
- `ip_manifest.json` — parameters, ports, clk/reset protocol, golden digest,
  board evidence, standalone synth resources.
- `README.md` — port table, parameter table, integration notes.

Per-IP independent verification (run from `cores/signal_processing/dsp/`):

```bash
iverilog -g2012 -o build_oss/ip/gw2a_dsp_<name>.vvp \
  ip/<name>/gw2a_dsp_<name>.v src/<core>.v

yosys -p "read_verilog -sv ip/<name>/gw2a_dsp_<name>.v src/<core>.v; \
  synth_gowin -family gw2a -top gw2a_dsp_<name>"
```

For `dds_nco` builds, run the tool from a directory where `sine256.mem`
resolves (a copy ships in `ip/dds_nco/`) or override `LUT_FILE`.

# comm_20k validation log

## 2026-09-24 UART RX continuous-frame optimization

PASS: `scripts/test_comm_uart_rx.ps1` runs 5 testbenches and compares all
5 raw selftest streams with the original golden files. `uart_rx.v` now
samples independently of acknowledgement and rearms after stop voting;
`comm_selftest.v` waits for transmitter ready before launching the next byte.
Package docs describe early valid and the one-entry overrun retention policy.
New tests: `tb_uart_rx_back_to_back.v`, `tb_uart_rx_boundaries.v`,
`tb_uart_rx_stream_board.v`; new board harness: `uart_rx_stream_board.v`.

Original delayed-ack contiguous-frame reproducer FAILED at byte 1; candidate
receives all 32 bytes. Existing URX digest `6BC47DCE`, all other COMM5 digests
and the full UART report are unchanged. Boundary tests cover false start,
held output, overrun, clk_en, bad framing, recovery and continuously high ack.

Built with `synth_gowin -noalu -family gw2a`, nextpnr-himbaechel at 27 MHz,
and gowin_pack, then programmed both stream and integrated images using
`openFPGALoader -b tangprimer20k`. Physical fx2lafw capture at 4 MHz on D0
contains 13 `URX2 PASS N=0020` reports and integrated `COMM5 M=FFFF P=FFFF`
with all 5 golden digests. The stream test uses internal loopback, not an
external RX cable. Integrated resource use: 4,619 LUT4, 1,184 FF, 0 DSP,
0 BSRAM; routed main-clock Fmax 144.80 MHz (not measured silicon Fmax).

All new logs, bitstreams, raw `.sr` captures, decoded reports and source
SHA256 hashes are under `artifacts/ip_optimization_20260924/` at repository
root. Exact commands and scope are in `docs/IP_OPTIMIZATION_STATUS.md`.
Historical evidence below is preserved.

Project: `cores/communication/primitives` — bus/protocol IP batch (uart_rx, uart_tx,
spi_master, i2c_master, axil_slave, fifo_async) for Sipeed Tang Primer 20K /
Gowin GW2A-LV18PG256C8/I7, 27 MHz, UART report @115200 (pin M11, COM24).

Toolchain: iverilog (s20251012), yosys 0.64+181, nextpnr-himbaechel,
apycula gowin_pack, openFPGALoader. All runs from `cores/communication/primitives/`.

## Independent golden model

`tools/golden_model.py` computes the exact folded byte stream per unit and
the FNV-1a digest, without reading RTL output (SOP trap T1):

    URX  stream= 20 bytes  digest=6BC47DCE
    SPIM stream= 14 bytes  digest=E4107F07
    I2CM stream= 18 bytes  digest=D6A89792
    AXIL stream= 28 bytes  digest=9B3A6985
    FIFO stream= 41 bytes  digest=B5FC9B84

`tools/gen_uart_golden.py` emits `sim/expected_report.mem` (544 bytes:
1 header line + 16 unit lines x 32 chars) for the UART report.

## Simulation results (iverilog)

`sim/tb_comm_selftest.v` — per-unit done/pass/digest plus raw folded-byte
dumps diffed against `sim/golden_*.txt`:

    UNIT 0 URX  done=1 pass=1 digest=6bc47dce   (== golden)
    UNIT 1 SPIM done=1 pass=1 digest=e4107f07   (== golden)
    UNIT 2 I2CM done=1 pass=1 digest=d6a89792   (== golden)
    UNIT 3 AXIL done=1 pass=1 digest=9b3a6985   (== golden)
    UNIT 4 FIFO done=1 pass=1 digest=b5fc9b84   (== golden)
    UNITS 5..15 skipped  digest=811c9dc5 (FNV seed)
    SELFTEST ALL-PASS done_mask=ffff pass_mask=ffff
    RESULT: PASS

Byte-level dump diffs (`sim/dump_*.txt` vs `sim/golden_*.txt`):
identical for urx, spi, i2c, axil, fifo (spi dump also contains extra
`miso` debug lines only).

UNIT_EN split-mask runs (each `RESULT: PASS`, disabled units report
seed 811C9DC5): 001F, 000F, 0010, 0001, 000E, 0000.

`sim/tb_top_uart_report.v` — decodes the 544-byte UART stream from `top`
and compares every byte to `sim/expected_report.mem`:

    tb_top_uart_report PASS

## Synthesis / P&R (OSS)

Commands:

    yosys tools/synth.ys                     # -> build_oss/top.json, yosys.log
    nextpnr-himbaechel --json build_oss/top.json --write build_oss/pnr.json \
      --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 \
      --vopt cst=src/top.cst                 # -> build_oss/nextpnr.log
    python3 gowin_pack-script.py -d GW2A-18 -o build_oss/comm_20k.fs \
      build_oss/pnr.json                     # -> 4.6 MB bitstream

Utilization (nextpnr, production top, build_oss/nextpnr.log):

    LUT4        4599/20736   (22%)
    ALU          930/15552
    DFF         1160/15552
    RAM16SDP4      2/648     (distributed RAM; BSRAM 0/46)
    DSP            0         (budget <=4)
    rPLL           1         (rdclk = 13.5 MHz on the global clock net)
    IOB            8/384

Timing: 0 errors, 0 warnings. clk Fmax 127.9 MHz, rdclk 620.7 MHz (both PASS).

FIFO read-clock history (three candidates tried on hardware):

1. Fabric toggle FF -> BUFG: 0 STA violations but rdclk never toggled on
   the board (FIFO unit hung, all_done=0, UART idle).
2. Gowin CLKDIV2: output is on the sector HCLK network only; nextpnr
   could not route it to all fabric clock sinks ("Failed to find a
   route ... net ... rdclk", routing failed).
3. Gowin rPLL (final): FCLKIN=27, IDIV_SEL=1, FBDIV_SEL=0, ODIV_SEL=64 ->
   CLKOUT = 13.5 MHz on the global network; rd_rst_n = rst_n && LOCK.
   Routes cleanly, STA clean, and works on hardware (see below).

## Board validation

(.boardlock protocol: retry mkdir every 15 s, owner file, <15 min session)

COM24 host path is broken on this host (same failure documented in the
dsp_20k validation: zero bytes even with a known-good bitstream), so the
physical UART line was captured with the Sipeed JTAG debugger in
fx2lafw mode instead. `src/la_debug_top.v` mirrors uart_tx to pin A11
(LA D0), status_pass->N6, status_fail->D11, heartbeat->B11, done[3:0] to
N9/N7/L9/N8 (`src/la_debug.cst`); it still drives the production M11
pin too.

Programmed `build_oss/comm_20k_la.fs` (rPLL build) with
`openFPGALoader -b tangprimer20k`, captured 2 s @4 MHz
(`build_oss/la_cap4.sr`), decoded D0 with sigrok-cli's uart PD:

    sigrok-cli -i build_oss/la_cap4.sr \
      -P uart:rx=D0:baudrate=115200:format=ascii -A uart=rx-data

Result — `doc/board_uart_la.txt` (report repeats ~4x in the capture):

    COMM5 M=FFFF P=FFFF
    U0 URX  P D=6BC47DCE
    U1 SPIM P D=E4107F07
    U2 I2CM P D=D6A89792
    U3 AXIL P D=9B3A6985
    U4 FIFO P D=B5FC9B84
    U5..UF ---- S D=811C9DC5

All five digests match the independent Python golden model exactly,
done_mask=FFFF, pass_mask=FFFF, status_pass pin=1, status_fail pin=0,
heartbeat toggling.

The final production bitstream `build_oss/comm_20k.fs` (rPLL build,
UART on M11) was also programmed under `.boardlock` and COM24 was read
for 8 s: 0 bytes received -> `doc/board_uart_com24.txt` is
intentionally empty; the COM24 host path remains broken and the
fx2lafw capture is the physical-pin evidence of record. Lock released
after the session.

## Bugs found and fixed during bring-up

- `spi_master`: `edge` is a reserved identifier -> renamed `edge_i`;
  `nbits` widened 5->6 bits so 32 is representable; selftest added
  wait-for-done-clear between transfers.
- `i2c_master`: byte shifter ran every clk_en tick instead of at bit
  boundaries -> captured garbage; shifted only on bit events now.
- `i2c_slave_model`: `buf` reserved -> renamed `cbuf`.
- `fifo_async`: Gray-pointer full/empty compared next-pointer values,
  creating a combinational full->wptr_next->full loop that latched X in
  sim; now compares current pointers (same fill behavior, no loop).
- `comm_selftest`: rd clock was gated off during reset (rd-domain state
  never reset) -> free-running rdclk; read FSM sampled `dout` one rdclk
  too early -> added `f_rdcap` pipeline stage; disabled units now drive
  their digest to the FNV seed instead of X; verdict could settle before
  `all_done` on a transient pass_r==done_w -> gated on all_done + settle
  counter; `===` used for digest pass checks; rdclk moved fabric->BUFG
  (dead on board) -> CLKDIV2 (unroutable) -> rPLL 13.5 MHz with
  rd_rst_n=rst_n&&LOCK (works); rd-domain regs got explicit power-on
  inits because the dedicated-clock domain has no edges while reset is
  held.
- `tb_top_uart_report`: started listening after `status_pass`, missing
  byte 0's start bit -> one-byte stream shift; now waits on
  `dut.all_done` and checks the verdict after the capture.

## Files

    src/: top.v top.cst comm_selftest.v uart_rx.v uart_tx.v spi_master.v
          spi_slave_model.v i2c_master.v i2c_slave_model.v axil_slave.v
          fifo_async.v
    sim/: tb_comm_selftest.v tb_top_uart_report.v tb_spi_dbg.v
          tb_i2c_dbg.v tb_fifo_dbg.v gowin_sim_models.v
          expected_report.mem golden_*.txt dump_*.txt
    tools/: golden_model.py gen_uart_golden.py synth.ys
    build_oss/: top.json pnr.json comm_20k.fs yosys.log nextpnr.log
    ip/: gw2a_comm_* wrappers + per-IP ip_manifest.json + README.md +
         MANIFEST.md
    doc/: VALIDATION_LOG.md board_uart_*.txt

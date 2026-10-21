# common_uart smoke harness for Tang Primer 25K

This directory contains an isolated board top for `common_ip_scaffold`'s
`common_uart`. It does not alter or integrate with the existing DSP/ISP top.
The top uses the Tang Primer 25K dock's 50 MHz oscillator on E2, UART TX on
C3, and debug status on E8. B3 is kept as the external UART RX input after the
self-test.

At power-up, a short power-on reset is followed by an internal UART TX-to-RX
loopback test of the six ASCII bytes `CIP25K`. The harness reads each byte from
the UART RX mailbox and compares it. When all bytes match, it transmits
`PASS common_uart` followed by CR/LF and sets E8 high after the final stop bit.
On a mismatch, UART error, or receive timeout, it attempts to transmit
`FAIL common_uart` followed by CR/LF; E8 blinks while failure is latched. UART
traffic starts with the loopback pattern, so the host console will see those
six bytes immediately before the result line.

## Simulation

From the repository root, with Icarus Verilog available on `PATH`:

```powershell
iverilog -g2012 -s tb_common_uart_smoke_25k -o $env:TEMP\common_uart_smoke_25k.vvp `
  cores/system/common_scaffold/peripherals/rtl/common_uart.v `
  cores/system/common_scaffold/board/tang25k/common_uart_smoke_25k.v `
  cores/system/common_scaffold/board/tang25k/tb_common_uart_smoke_25k.sv
vvp $env:TEMP\common_uart_smoke_25k.vvp
```

Expected output:

```text
PASS common_uart_smoke_25k: loopback, PASS and FAIL paths verified
```

The self-checking testbench decodes the board TX stream, checks `CIP25K` and
the PASS line, and uses a second DUT with its internal RX held high to exercise
the bounded-timeout FAIL line and error latch.

## Optional 25K resource build

`run_device_flow.py` stages the top and `common_uart.v` under this directory's
`build/` folder and invokes the existing
`cores/signal_processing/dsp_isp_library/board/tang25k/device_flow.py` flow for
`GW5A-LV25MG121NES`. The shared flow generates the matching CST and performs
GW5A synthesis, P&R, and packing. The build wrapper stages `tang25k.cst` with
the RTL before invoking the shared flow.

```powershell
python cores/system/common_scaffold/board/tang25k/run_device_flow.py
```

## Validation record (2026-10-15)

- Icarus compile and self-checking simulation: **PASS**.
- GW5A synthesis, place-and-route, and packing: **PASS**. The report records
  517 LUT4, 223 DFF, 0 BSRAM, 0 MULT12, and post-route clock results of
  258.67/334.78 MHz. The generated `build_25k_summary.json` has status
  `BUILD_PASS_NOT_BOARD`, because that build status is intentionally separate
  from board validation.
- JTAG SRAM configuration: **PASS** on the detected GW5A-25
  (`IDCODE 0x1281b`). UART capture on `/dev/ttyUSB1` at 115200 8N1 returned
  `CIP25KPASS common_uart`; `openFPGALoader` completed SRAM loading with exit
  code 0. The bitstream SHA-256 was checked after transfer.
- The board check covers this `common_uart` smoke harness only. It loads the
  volatile FPGA SRAM configuration; nonvolatile SPI flash was not written.
- These results do not claim board-level verification for the other
  `common_ip_scaffold` modules.

## Image filter functional consistency harness (2026-10-15)

`image_filter_selftest_25k.v` drives the repaired synchronous frame filter
with a fixed 4x4 grayscale frame, checks all 16 pixels and frame markers
against golden values, and transmits the digest over UART. The expected line
is `FILTER PASS D=378E8AAB`.

- Icarus simulation: **PASS**, `FILTER PASS D=378E8AAB`.
- GW5A-25 synthesis, place-and-route, and packing: **PASS**. The isolated
  top uses 12,528 LUT4, 613 DFF, 2 BSRAM, and 0 MULT12; timing results are
  100.61/106.13 MHz. This is below the device-flow gates, but is a build result
  rather than a complete board result.
- Bitstream SHA-256:
  `2e41a8ed86dc347fcee916720a32ca9dc73979875f1ca7d117313660d93642f8`.
- Tang 25K SRAM programming and UART readback: **PASS** on GW5A-25
  (`IDCODE 0x1281b`). `COM44` at 115200 8N1 returned
  `FILTER PASS D=378E8AAB`; the programmer exited 0 and the programmed image
  SHA-256 matched the build artifact. The raw UART/JTAG record is
  [board_uart_20261016_014945.txt](build/image_filter_selftest_25k/board_uart_20261016_014945.txt).
- This board result covers the fixed 4x4 grayscale opening self-test only;
  it does not validate the other image-processing modules. Configuration was
  loaded into volatile SRAM; SPI flash was not written.

The separate geometry inverse-map board self-test is documented in
[image/geometry/board_selftest](../../image/geometry/board_selftest/README.md).
It checks a fixed 4x4 perspective map over UART and also loads its image only
into volatile SRAM.

Build with:

```powershell
python cores/system/common_scaffold/board/tang25k/run_image_filter_selftest_25k.py
```

The self-checking testbench is `tb_image_filter_selftest_25k.sv`; the build
summary, bitstream, and tool logs are under `build/image_filter_selftest_25k/`.

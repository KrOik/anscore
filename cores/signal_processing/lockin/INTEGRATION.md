# Integration

`lockin4` accepts synchronous four-lane signed16 vectors with four64-bit
timestamps. It integrates quadrature products over a power-of-two window,
then serializes four amplitude/phase results through the reused CORDIC.
See SPEC.md for arithmetic and timing. `virtual_adc4` provides scheduled
controlled inputs; it is not an ADC peripheral or an analog model.

`lockin_replay` owns finite transactions, timeout and abort. `lockin_config`
and `lockin_control` provide atomic command admission and transport-neutral
CSR access. Connect exactly one CSR master at a time; arbitrate externally
if adding another master. There is one outstanding request and one held
measurement result. See CSR.md and REPLAY.md for side effects and errors.

`examples/25k/lockin_top.v` binds the unchanged shared UART and CSR transport
to the control interface. It uses the 50MHz E2 oscillator, C3 TX, B3 RX and
probe pins G5,F5,G8,G7,H7,H8,J5,H5. GPIO are LVCMOS33. These are 25K
constraints; do not program this image into the currently attached20K.
Power-on reset lasts65535 core cycles. UART default434 clocks/bit gives
approximately115200baud. Probe bits7..0 are error-present,result-held,
pending-config,command-valid,command-ready,commit,request-valid,request-ready.
These combinational probe levels aid debug and do not prove numeric results.

Build after `. ./scripts/env.ps1`:

```
python cores/signal_processing/lockin/tools/build_board.py
```

The build freezes all source/ROM/constraints, derives a64-bit fingerprint,
synthesizes GW5A, routes at50MHz and packs an SRAM image. It never downloads.
ROM relative paths resolve inside the frozen source snapshot. The UART top
is supplementary: mandatory hard-user-JTAG runtime integration and physical
25K acceptance remain open.

The UART top simulation uses8 clocks/bit for speed and covers real serial
input/output, shared transport, configuration and numerical results:

```
python cores/signal_processing/lockin/tools/test_uart.py
```

This is not a115200baud physical test. The transport-neutral CSR test adds
response stalls and a commit while a measurement is active; the UART test
can queue the next commit while the prior result is held.

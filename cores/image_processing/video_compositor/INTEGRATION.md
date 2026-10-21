# Integration and board window

All current modules use one synchronous system clock. Connect elastic streams
only to ready/valid consumers. video_route4 requires stable full metadata under
backpressure; physical raster timing cannot stall and needs frame/line buffering
before accepting an external routed source. That adapter is still open.

`examples/25k/video_top.v` is a supplementary UART/debug example, not a display
PHY. Target GW5A-LV25MG121NES,50MHz E2,UART RX B3/TX C3. BIT_CYCLES434 at50MHz
is approximately115207baud; simulation uses8clocks/bit. UART framing and
CRC8 are unchanged from uart_csr_transport. Power-on reset holds for65535clocks.

AddressFC is reserved in every UART window. Read returns selected bank0..3;
write0..3 selects a bank, larger values error without changing it. Reset bank0.
Other UART byte addresses map to `{bank,address}` in CONTROL_CSR.md. Access
one transaction at a time and validate response address/status/CRC. A new host
session must explicitly select bank0 rather than assume a previous selection.

Eight probe outputs use CH0..7 G5,F5,G8,G7,H7,H8,J5,H5 (25K mapping only).
Bits0..2 are lane running,3 any CRC event,4 any pending configuration,5 any
occupied result,6 any timing error,7 any overflow. Outputs are registered,
adding one system-clock observation delay. Short pulses may require a suitable
LA rate or dedicated stretching; no real capture is claimed by simulation.
These pins must not be confused with the currently connected20K calibration.

```
. ./scripts/env.ps1
python cores/image_processing/video_compositor/tools/test_uart.py
python cores/image_processing/video_compositor/tools/build_board.py
```

Build freezes all sources/constraints/build script and produces target-specific
P&R reports/hash; never programs hardware. Do not download a25K image to20K.
Hard user-JTAG runtime remains a separate open gate; UART does not substitute.

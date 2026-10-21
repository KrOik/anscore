# IP-04 test shell — development status

`logic_probe8` is a passive four-page observation mux with registered 8-bit
output. All inputs and page configuration belong to `clk`; no CDC is provided.
Active-low reset asynchronously blanks pins. Pages 4–7 blank pins. Page changes
take effect at the next rising edge, as do observed signal changes (one register
stage). No signal returns from probes into the functional datapath.

The caller supplies page meanings in `probe_map.yaml`. Page 1 selects the actual
protocol used, not simultaneous UART and SPI. A sampled clock input is not a
forwarded physical clock; use a controlled tick and document its division.
The module does not stretch events or reduce their rate automatically.

Only pin mapping has physical acceptance. Probe paging, protocol capture and
same-bitstream runtime JTAG loading remain unaccepted until integrated tests.
Calibration established 2 MS/s capture; analyzer input ratings remain unknown.

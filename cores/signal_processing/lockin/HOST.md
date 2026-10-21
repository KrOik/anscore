# Host numerical acceptance

`lockin_host.py` uses a supplied synchronous `bus.access(byte_address,
optional_write_word)` callback. The callback must raise on transport/CSR
errors. It does not implement hard-user-JTAG; use an independently verified
backend before claiming that transport. `run_uart.py` reuses the existing
buffer/DMA UART transport unchanged as supplementary access.

The runner validates a completed50MHz25K build, current source hashes, packed
image hash and hardware fingerprint before any configuration write. A supplied
image hash is not proof that every bit of the loaded image was physically
read back. It runs three coherent frequencies with four different amplitudes
and phases per run. It verifies exact signedIQ, amplitude tolerance12counts,
phase tolerance0.06rad, ID/error/counters, timestamp span, applied version and
held completion. Completion polling is bounded by time and count. Only a
verified saved result is acknowledged; failure leaves the result for diagnosis
and never retries writes automatically. Partial captures and wire exchanges
are retained after failure.

```
python cores/signal_processing/lockin/tools/test_host.py
python cores/signal_processing/lockin/tools/run_uart.py --port COMx --build-summary artifacts/lockin_dsp_25k/board_TIMESTAMP/summary.json --output artifacts/lockin_dsp_25k/physical_UNIQUE
```

The latter requires an already loaded matching25K image and actual working
UART RX wiring. It is not automatically run against the attached20K.
Successful hardware runs emit per-runJSON, raw exchangeJSON and errors.csv.
Classify them as board-controlled digital input; no analog end-to-end claim.
Physical timestamp clock accuracy and oscillator calibration remain separate.

Host regression invokes the real RTL CSR simulation to obtain numerical
register values, verifies them through the host code, then injects eight
numeric/accounting corruptions, wrong fingerprint and completion starvation.
All10 negative cases must fail without result ACK. This test does not replace
physical serial or JTAG measurement.

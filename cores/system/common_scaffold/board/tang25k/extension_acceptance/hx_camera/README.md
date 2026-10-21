# HX711 and camera board-output consistency candidate

This is an isolated FPGA self-test wrapper, not a new production IP. The frozen production HX711 controller, camera register sequencer and shared I2C PHY are instantiated without edits. Synthesizable digital sensor peers connect to their actual serial pin signals inside the FPGA. There are no physical HX711/camera peripherals or external sensor wiring in this test.

On completion the UART at 50 MHz / divisor 434 repeatedly emits exactly 24 bytes, every approximately 0.5 seconds:

```
PASS HX_CAMERA N=3 C=2\r\n
```

Any actual comparator, peer protocol checker or watchdog error changes the prefix to `FAIL`. Host capture must compare actual CR/LF bytes, rather than the literal backslash notation above.

Coverage: HX711 emits three complete 24-bit serial words -1, -8388608 and +8388607. The controller result values, sequence indices and current/next mode tags 0->1, 1->2 and 2->0 are checked, alongside exact 26/27/25 clock pulses and FIFO hold/counts. Camera executes separate I2C 16-bit register-address and SCCB 8-bit register-address sequences, each WRITE followed by masked VERIFY and END. The pin peer checks every byte and START/STOP sequence. I2C uses repeated START, SCCB uses STOP-separated reads and mixed high/low ninth DC bits; final read byte uses released NACK/NA. Verification value A5 matches expected A0 under mask F0.

This bounded board wrapper does not repeat every host simulation corner: camera retry/delay/error matrices and HX711 saturation/timeout/power-management boundaries remain in the independently reviewed module regressions. It establishes FPGA output consistency for the stated serial transactions, not analog sensor accuracy or physical IO electrical compliance.

Normal top-level UART decoding simulation passed. Independently corrupting one HX711 serial data bit and one camera expected wire byte each caused the wrapper to emit the exact FAIL UART. Fault reports and text logs are retained. Temporary simulator executables were removed by TemporaryDirectory.

The first `run_build.py` attempt passed simulation and synthesis but the older default nextpnr could not place RAM16SDP4. It is retained in `build/`. `run_qualified_build.py` stages and re-verifies identical production/wrapper inputs, uses existing synthesis with `-nolutram`, and calls the existing isolated OSS route helper with the corrected chip database. Its output is retained in `build_nolutram/`.

The qualified route completed: 1740 LUT4, 890 DFF, zero BSRAM/DSP, reported Fmax 59.92 and 58.52 MHz. Resource, route and 50 MHz setup gates passed. The existing helper reports hold evidence/model qualification as unproven and therefore did not pack. This agent did not modify gates, pack, program JTAG or open UART. Root owns any subsequent functional-only pack/capture procedure and must retain the HOLD_UNPROVEN limitation. This is not complete timing signoff.

`source_manifest.json` contains status PASS and absolute input-file paths with SHA256, including production and staged RTL, embedded synthesizable models, build scripts, UART fixture, testbench, simulation and source-check evidence. `build_nolutram/build_input_sha256.json` and `post_build_source_check.json` establish common simulation/build source closure before/after implementation. Preserve source, routed JSON, logs and other existing outputs until root completes hardware validation and authorized cleanup.

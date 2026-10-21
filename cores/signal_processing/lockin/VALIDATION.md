# IP-06 validation status

Current state: digital RTL and supplementary UART simulation pass. Full25K
route/pack is in progress; physical25K controlled-input/JTAG/LA acceptance
has not occurred. Analog end-to-end validation has not occurred. These open
gates prevent L3/L5 release claims.

Run from repository root after `. ./scripts/env.ps1`:

| Command under cores/signal_processing/lockin/tools/ | Evidence covered |
|---|---|
| `python .../test_lockin.py` | Three frequencies,12 amplitude/phase combinations, exactIQ, calibration, timestamp errors, reset |
| `python .../test_live.py` | 768 scheduled four-lane samples, actual simulated timestamp events,12 error-table rows, overflow |
| `python .../test_replay.py` | Five clean runs, five error completions, bounded abort, recovery, held result |
| `python .../test_config.py` | Atomic byte writes/commit, deferred update, stalled command, exactly-once admission |
| `python .../test_control.py` | Real CSR/ADC/lock-in, queued runs, coherent result readback, independentIQ/polar values |
| `python .../test_uart.py` | Real bit-serial board-top path, accelerated8clock UART bits |
| `python .../test_host.py` | Actual RTL result fixture, host verification,10 corruption/identity/timeout rejections |
| `python .../build_board.py` | Frozen source/ROMs, full25K synthesis,50MHz P&R and pack; no download |

Each automated runner writes a timestamped artifact directory with source
hashes, logs and summary. Numerical limits remain12 amplitude counts and
0.06radians. ExactIQ has no tolerance. Neither software-derived ideal values
nor simulated oscillator clocks establish actual board frequency accuracy.

Latest evidence and failed attempts are recorded chronologically in
`work/ip_asset_25k/STATUS.md`. Do not select only a passing earlier build when
the current source has changed. The host refuses source/image/fingerprint
mismatches. An isolated synthesis result is not complete-system utilization
or routed timing. Consult the full build's summary and P&R report.

Remaining acceptance: successful complete25K route/pack; matching25K SRAM
download; working hard-user-JTAG runtime reads/writes; three frequency/four
lane error tables from actual board-controlled inputs; LA event/probe capture
with matching image and actual clock/CE. UART evidence is supplementary.
Current physical hardware was confirmed as Primer20K, so no25K image has
been downloaded. Distribution licenses must also be resolved before release.

# Porting Notes: mic_xcorr to Tang Primer 20K 7micarry

## Reference Sources

- SiPEED official Tang Primer 20K examples: `official/TangPrimer-20K-example`.
- Real DOA reference requested for this project: `references/mic_xcorr`.
- Useful reference files:
  - `references/mic_xcorr/src/xcorr.v`: sample-window cache and lag-scanned multiply-accumulate cross-correlation.
  - `references/mic_xcorr/src/mic_data_store.v`: microphone sample buffering model.
  - `references/mic_xcorr/src/mic_sample.v`: microphone sample capture.

The older MachXO2 LED project is not used as a DOA reference. This project only keeps the local SK9822-style LED-frame latching idea where it helps avoid mid-frame LED artifacts.

## Current Implementation

`cores/acquisition/micarray_doa` is a Tang Primer 20K SRAM-buildable 6+1 microphone direction tracker:

- `i2s_quad_rx_stub.v`: FPGA drives `MIC_BCK/MIC_WS`, captures `MIC_DAT0..3`, and exposes six ring microphones plus one center sample. It now uses the fixed `mic_xcorr` BCLK/WS timing and tested left/right channel order.
- `micarray_doa_core.v`: uses a `mic_xcorr`-style short-window cross-correlation flow. It caches a sample window, scans lags, multiply-accumulates three opposite microphone pairs, extracts three best delays, and maps the plane-field vector to 12 horizontal sectors.
- `top.v`: instantiates the DOA core with `WINDOW_SAMPLES=16`, `MAX_LAG=4`, `MIN_TOTAL_ENERGY=300`, and a 4:1 DOA sample decimator so the lag scan completes without overrun on the current board.
- `led_direction_filter.v`: gates display by energy, DOA valid bit, and sector score gap. It also requires four matching result frames before enabling or jumping to a non-adjacent sector.
- `sk9822_driver.v`: displays exactly three LEDs for an active direction: center sector plus adjacent sectors.
- `doa_uart_reporter.v`: streams DOA, energy, delay, vector, score, overrun, and heartbeat diagnostics over UART.

This is a real FPGA cross-correlation plane-field tracker, not a full GCC-PHAT or beamforming implementation. It is intended as the current hardware-complete bring-up baseline for Tang Primer 20K + SiPEED 7micarry.

## LED Behavior

- The 12 SK9822 LEDs represent 12 horizontal sectors.
- `display_led_index` is the center sector after filtering.
- Only `display_led_index`, `display_led_index - 1`, and `display_led_index + 1` are lit while `direction_active` is true.
- Center red brightness follows the current board-calibrated mapping:
  - `red = 255` when `report0 >= 8192`
  - otherwise `red = max(8, report0 >> 5)`
  - side LEDs use half of the center brightness.
- LED active gate is `report0 >= 450`, `direction_valid=1`, `score_gap >= 48`, and four confirmed frames for a newly acquired/non-adjacent direction.
- LED off hysteresis gate is `report0 < 250`.
- UART DOA frame `flags[0]` reports the actual filtered LED active state, so monitor `-ActiveOnly` follows the real lamp output rather than the raw DOA gate.

The most recent board monitor run after the half-brightness side LED adjustment showed `ovf=0`, `valid=2310`, and `active_led=1806` out of 2380 received frames over 5 seconds. Active UART lines showed only three LEDs, for example `leds=(07:009,08:018,09:009)`.

## Pin Constraints

`src/top.cst` contains the active pin assignment:

- `clk`: `H11`
- `sk9822_ck`: `P9`
- `sk9822_da`: `T9`
- `uart_tx`: `M11`
- `uart_rx`: `T13`
- `mic_d0`: `P8`
- `mic_d1`: `T8`
- `mic_d2`: `R8`
- `mic_d3`: `T7`
- `mic_ws`: `P6`
- `mic_bclk`: `T6`

Evidence chain:

- SK9822 pins are from `official/TangPrimer-20K-example/Micarray/SK9822_RGB_LED/src/top.cst`.
- 7mic connector signals are from `datasheets/Tang_Primer_20K_Dock-3713_Schematics.pdf` page 9/9.
- The working `references/mic_xcorr/src/top.cst` was used to cross-check the mic connector mapping.

## Verification Flow

Run RTL simulation and structural checks:

```powershell
.\scripts\test_micarray_doa_sim.ps1
```

Expected simulation passes:

- `PASS: micarray_doa_core xcorr direction test`
- `PASS: i2s_quad_rx_stub channel-order test`
- `PASS: virtual spatial-field DOA and 3-LED tracking test`
- `PASS: doa_uart_reporter frame format test`

Build the SRAM bitstream:

```powershell
.\scripts\build_micarray_doa_with_oss.ps1
```

Program Tang Primer 20K SRAM:

```powershell
.\scripts\program_micarray_doa.ps1
```

Monitor using FT2232 interface 2:

```powershell
.\scripts\run_micarray_ftdi_monitor.ps1 -Interface 2 -Seconds 10 -ActiveOnly
```

For a normal COM-port UART path:

```powershell
.\scripts\run_micarray_uart_monitor.ps1 -Port COM23 -Seconds 10 -ActiveOnly
```

The monitor summary should show nonzero `valid` and `active_led` counts when sound or board noise exceeds the current gates. Active frames should print exactly three LEDs in `leds=(left,center,right)` form, and `ovf=0` should be stable after the 4:1 decimator.

## Current Limits

- SRAM programming is volatile. Use a Flash programming flow if the image must survive power cycling.
- Current DOA accuracy is limited by the short 16-sample window and `MAX_LAG=4`, chosen to fit and route reliably while tracking in real time on GW2A-18.
- Thresholds are calibrated to the observed board data in this setup. Different microphones, gain, room noise, or clocking may need retuning of `MIN_TOTAL_ENERGY`, `LED_ON_ENERGY_GATE`, `LED_OFF_ENERGY_GATE`, and `LED_SCORE_GAP_GATE`.

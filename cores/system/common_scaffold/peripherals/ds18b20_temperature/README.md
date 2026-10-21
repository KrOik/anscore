# DS18B20 external-powered measurement

`ds18b20_temperature` performs reset/presence, Skip ROM (single device) or Match ROM (64-bit snapshot, low byte first), Convert T, completion polling, a second reset/selection, Read Scratchpad (9 bytes), and Dallas CRC8. Successful results expose signed 16-bit temperature in units of 1/16 degree Celsius. Configuration-byte resolution masks the 3/2/1 undefined LSBs for 9/10/11-bit conversion. The 85 degree power-on value remains a valid returned value. Family and ROM CRC are not validated by this transaction core; ROM enumeration belongs to `onewire_rom_search`.

The bus requires an external pull-up and an externally powered sensor. Connect `ow_drive_low` to an open-drain output enable; never actively drive the line high. Parasite-power strong pull-up, analog signal integrity and physical sensor/board tests are outside this implementation's evidence.

## Timing and host protocol

Supported clocks are integer MHz, 1 through 250 MHz; timeout is 1 through 10,000,000 microseconds. These are divider legality limits, not a claim that 250 MHz FPGA timing closes. Illegal configurations complete with error 1 without driving the bus. All physical timers and the two-stage input synchronizer run independently of host CE. Reset low is 480us, total 960us; presence is sampled around 71us after release, inside both earliest/shortest and latest-onset windows. Writes are low 6us/60us, reads low 3us, slots 70us. The effective pin read sample is 14us, compensating two synchronizer clocks. No coefficient or other project state is touched.

`ce && start_valid && start_ready` snapshots Match/Skip and ROM. Timeout starts at the first completion-read slot. A ready value physically sampled at or before the timeout deadline wins; a later sample cannot rescue timeout. Synchronizer observation latency does not shorten the deadline or grant additional physical time. Completion can wait for the current 70us slot to finish. A conversion already accepted by the sensor is not rolled back by abort.

`result_valid` holds temperature, resolution, and all 72 scratchpad bits immutable until `ce && result_ready`. Abort during this hold records error 6 but retains the result until acknowledged. `done_valid/error_code` then hold until `ce && done_ready`. Abort is sampled only with CE, and finishes the current reset or bit slot without truncating bus timing. Synchronous reset has priority even with CE=0 and immediately cancels a transaction on the reset clock. Errors: 1 illegal parameters, 2 stuck low, 3 absent presence, 4 conversion timeout, 5 scratchpad CRC, 6 abort.

## Reproduce

Run Python scripts from this directory or the repository root: `test_case.py`, `test_temperature.py`, `test_timing.py`, `test_parameters.py`, `test_protocol.py`, `test_long_conversion.py`, and `synth.py`. They use Icarus Verilog and Yosys from the existing tooling module. Build/simulation intermediates use automatically removed C: temporary directories. Small logs and source-bound JSON evidence remain here.

The independent device model parses only physical open-drain transitions; it checks complete Match ROM byte order and function commands and drives timed presence/data replies. Tests cover positive/negative limits, 85C, all resolutions, CRC error, first/second absence and stuck-low, held results/CE/abort/reset, 750ms conversion, strict deadline boundaries at 1/27/250MHz and endpoint presence windows. `fetch_references.py` downloads actual public OneWire and DallasTemperature code into memory and records SHA256/excerpts in `references.json`; original RTL is not copied from those software implementations.

Isolated `synth_gowin -nodsp; check -assert` profiles use the actual top at 1/27/250MHz: 598/632/644 LUT-class cells, 0 DSP and 0 BRAM. These are isolated synthesis counts, not P&R or board acceptance. No physical DS18B20 validation has been performed.

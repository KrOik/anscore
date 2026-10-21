# Sensor I2C board-internal acceptance wrappers

This directory contains three independent Tang Primer25K test cases for the frozen DS3231, ADS1115 and SHT3x RTL. Each case instantiates the real DUT and the unchanged shared I2C physical engine. Its SCL/SDA open-drain outputs connect to a synthesizable synchronous scripted slave inside the FPGA. No external sensor connector or physical sensor is tested. MPU6050 is excluded and is not included here.

The slave decodes START/STOP/address/write/read edges and drives byte responses at the pin interface. The wrapper checks independent expected application values and transaction counts, then latches PASS or FAIL. UART repeats a result every half second at115200baud with a50MHz input clock. Tokens explicitly say PINLOOP:

```
PASS DS3231 PINLOOP\r\n
PASS ADS1115 PINLOOP\r\n
PASS SHT3X PINLOOP\r\n
```

DS3231 checks2199-12-31 weekday7 at23:59:58, century, OSF/alarm flags, full register/status/seconds-read sequence. ADS1115 checks the exact configuration C583, busy then ready OS polls and signed sample0x8001. SHT3x checks command2400, raw BEEF/1234, independent fixed CRC92/37 and converted85523mC/7111mpercent. The shortened one-microsecond SHT wait is for the internal synthetic slave, not an assertion about a real sensor's conversion time.

`test_wrapper.py` runs all three cases and fault variants, decoding actual UART start/data/stop bits and matching the exact complete line. Fault variants change a DS seconds value, ADS sample bit, or SHT CRC, and must emit FAIL. `stage_cases.py` stages each thin top plus the unchanged actual sources, verifies all source hashes before/after simulation, repeats both positive/negative UART simulations and writes exact ASCII `expected_uart.txt`, `case.json`, `build_status.json` and `build_input_sha256.json`. The latter binds staged files to upstream package-relative SHA256. `frozen_dut_binding.json` separately checks each production RTL against its owner's source freeze and records the shared-PHY hash. The local CST keeps the existing50MHz E2 clock/C3 UART TX/B3 RX/E8 debug mapping.

Commands from repository root:

```powershell
python -B cores/system/common_scaffold/board/tang25k/extension_acceptance/sensor_i2c/test_wrapper.py
python -B cores/system/common_scaffold/board/tang25k/extension_acceptance/sensor_i2c/stage_cases.py
python -B cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/extension_acceptance/sensor_i2c/cases/ds3231 --attempt sensor_ds3231 --no-lutram
```

Use fresh case directories for any restaging/rebuild; the scripts preserve existing artifacts rather than overwrite synthesized designs. The ADS1115/SHT3x build calls use their matching case and attempt names. The established acceptance48 builder uses open synthesis with `-nolutram` and the existing repaired GW5A chip database/isolated open router runtime. It verifies simulation hashes and preserves its resource/timing/hold gates. A routed netlist with missing qualified hold evidence is reported as `ROUTE_GATE_FAIL_NOT_PACKED`; it is not called a successful build, packed image or board PASS. See each actual `build_sensor_*_summary.json` and final local report for the measured status.

The owner performs no JTAG programming or physical UART access. Root exclusively owns the board and any subsequent acceptance decision. Retain route/source/log/bitstream artifacts until root finishes; root can then remove only the new large intermediates. Temporary local simulation executables and generated testbenches use TemporaryDirectory and are automatically removed. Baseline artifacts, registered sources and integration registries are untouched.

The new `cases/sht3x_pipeline` stages the separately revalidated pipelined SHT3x RTL (owner freeze1f934f56d15995720da6e23199009462dd26efae104e2f0f98b4eda0431ca04c). It retains the original full raw/CRC/engineering-unit checks and UART token. The original `cases/sht3x`50MHz failure is preserved. The stopped raw-only files remain excluded. See the new case frozen_dut_binding.json for the updated owner/source relationship.

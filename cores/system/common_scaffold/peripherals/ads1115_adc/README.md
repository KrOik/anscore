# ADS1115 single-shot ADC transactions

`ads1115_adc.sv` is a synthesizable ADS1115-specific I2C transaction controller. It writes configuration register 1, polls its OS bit, and reads conversion register 0 as a signed two's-complement 16-bit sample. Address 0x48 through 0x4b, all eight MUX/PGA/data-rate encodings are accepted and latched at the CE-qualified command edge. PGA encodings 5/6/7 all mean ±0.256 V in the TI table. There is no numeric voltage conversion or analog calibration.

The configuration writes OS=1, MODE=1, comparator disabled (COMP_QUE=11), with other comparator bits zero. Per the TI datasheet, writing OS=1 starts a single conversion when powered down; writing it during an ongoing conversion has no effect. Reading OS=0 means converting and OS=1 means idle/data ready. **Integration precondition:** the device must be idle in single-shot/power-down mode before accepting a command, and exclusively owned until completion. This controller does not claim safe takeover from an external continuous-conversion user or another master. Reset during a conversion cancels the host transaction but does not reset the external ADC; wait until it is idle before another command. Data are only read after OS=1. The digital filter has single-cycle settling, but source impedance/analog input settling, input voltage limits and supply/reference integrity remain external analog requirements. No ALERT/RDY pin support or comparator/threshold programming is claimed.

`MAX_POLLS` (1..2147483647) bounds completed configuration reads, including the final successful read. It is a transaction count, not a clock-cycle or millisecond timeout. Select it from the actual bus clock, data rate (8..860 SPS), ADC oscillator tolerance and system timing; defaults are not a universal time guarantee. Clock stretching has a separate bounded transport timeout. OS is never rewritten during polling. Each register read uses pointer-write + repeated START and reads MSB then LSB with ACK then final NACK.

`start_ready` advertises IDLE even if CE=0, but acceptance requires `ce && start_valid && start_ready`. Physical I2C advances under CE=0. `result_valid`, signed `sample`, final `config_readback` and `polls` remain stable until `ce && result_ready`; then a separately held `done_valid/error_code` requires `ce && done_ready`. Synchronous active-low reset has priority over CE, releases open-drain transport and clears host state. A command snapshots all configuration inputs. Result-valid is asserted only on success; consumers must not use stale sample fields on an error.

Error codes: 1 transmitted-byte NACK (STOP attempted), 3 clock-stretch timeout, 4 arbitration conflict, 5 busy/stuck bus, 6 OS poll exhaustion, 8 invalid address/static parameters. Physical STOP failure overrides a pending logical NACK. This is not a full multimaster bus recovery engine.

Transport is the unchanged external package dependency `peripherals/i2c_eeprom/i2c_eeprom_phy.sv`, recorded by package-relative SHA256 in `dependency_sha256.json`; `rtl_sources.f` lists the local core only. Add the dependency when compiling. No PHY code is copied.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/peripherals/ads1115_adc/test_transactions.py
python -B cores/system/common_scaffold/peripherals/ads1115_adc/synth.py
```

The independent device model drives physical open-drain pins, decodes addresses/registers/writes, snapshots configuration/conversion bytes, holds old conversion data while busy, and releases new signed data only at modeled readiness. It checks exact START/STOP/byte/ACK counts. Tests cover host backpressure/CE, descriptor snapshot, MUX/PGA/rates, signed boundaries, poll limit, NACK, arbitration, stuck bus, stretch, reset and invalid parameters. The model is a digital transaction oracle; it is not an analog ADC model. Verification and isolated Gowin synthesis do not constitute a real ADS1115/board test.

`references.json` records actual fetched TI datasheet and Adafruit ADS1X15 driver URL, bytes, SHA256 and excerpts. `fetch_references.py` fetches into memory and retains no PDFs/downloads. `source_freeze.json` and `final_validation.json` bind inputs and resulting evidence; generated HDL binaries and temporary workspaces are automatically removed.

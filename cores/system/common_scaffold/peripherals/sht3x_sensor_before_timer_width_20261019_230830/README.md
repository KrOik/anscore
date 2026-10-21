# SHT3x single-shot temperature/humidity controller

This new core implements SHT30/31/35 single-shot measurements over an external open-drain I2C bus. A full projects RTL/manifest/Python text and filename search found no SHT3x implementation. The existing DS18B20 is a1-Wire temperature-only sensor and is not equivalent. Existing EEPROM RTL is unchanged: this core reuses peripherals/i2c_eeprom/i2c_eeprom_phy.sv read-only, with package-relative SHA256 in dependencies.json and every evidence report. No PHY source is copied.

The real Sensirion SHT3x-DIS datasheet was downloaded from Adafruit's public mirror (976828bytes, SHA in references.json), together with Adafruit and Sensirion open-source drivers. The sensor commands and CRC properties were checked from actual content. The datasheet gives maximum measurement times4/6/15ms; defaults wait5/7/16ms for low/medium/high repeatability. The complete extracted datasheet text is retained, while the PDF/download buffers were memory-only. The open-source drivers informed API/CRC/command choices; no driver implementation was copied. Adafruit's65536 approximation is not used: engineering values here use exact65535 division.

## Interface and sequence

req_address accepts7-bit0x44 or0x45; req_repeatability0/1/2 selects low/medium/high and command0x2416/0x240B/0x2400. All requests use clock-stretch-disabled measurement commands. Caller must wait until the sensor has powered up and match sensor supply/pullups/timing. This core does not issue periodic/heater/reset/status/break commands or manage the physical RESET pin.

A descriptor transfers on req_valid&&req_ready; req_ready includes rst_n&&ce&&!abort&&IDLE. Address and repeatability are snapshotted. CE gates new requests only. Physical byte engine, measurement wait, retry gap and completion continue on physical clocks while CE=0. Output uses standard out_valid&&out_ready, independent of CE. Do not apply a CE-qualified consumer contract to this output. One outstanding measurement/response is supported; a held response blocks new requests. Every output field stays stable under backpressure. busy excludes IDLE and the held-response state.

Sequence: START/address-W/24/command-low/STOP, selected measurement wait, START/address-R. A read-address NACK means sensor busy: STOP, retry gap, then another START/address-R, bounded by READ_ATTEMPTS total read-address attempts. Writes are never silently retried; an initial write-address NACK is error2. On read ACK, receive temperature-MSB/LSB/CRC and humidity-MSB/LSB/CRC. ACK the first5bytes, NACK byte6, STOP. out_read_attempts counts actual read-address responses, including busyNACKs. Each accepted descriptor clears prior status/data before acquisition.

The shared PHY supports bounded legal electrical clock stretching, busy/stuck bus detection and arbitration checks even though this sensor command does not request measurement stretching. Normal I2C pin timing is independent of host CE. External open-drain line resolution and pull-ups are required; outputs are low-enable signals only. Choose CLOCK_HZ/HALF_PERIOD_CYCLES and pullups to meet real I2C rise/fall timing. The PHY's integer divider guard is not a blanket certification of a bus speed.

## Data and errors

out_temperature_raw/out_humidity_raw are16-bit sensor words. CRC8 polynomial0x31, initialFF, non-reflected, xorout0 protects each separate2byte word; the public fixture BEEF produces92. out_crc_bad bit0 indicates temperature CRC mismatch, bit1 humidity. CRC errors still return received raw words for diagnostics, but engineering outputs remain0. Partial/raw values on any error are not valid measurements.

Valid engineering outputs round to nearest integer (half-up):

    temperature_mC = -45000 + floor((175000*raw_T +32767)/65535)
    humidity_mpercent = floor((100000*raw_RH +32767)/65535)

Temperature is signed19-bit milli-degrees Celsius (-45000..130000); humidity is unsigned17-bit milli-percent RH (0..100000, where100000=100%). Exact divide-by65535 uses quotient/remainder decomposition, not a generic divider and not a65536 approximation. Both complete16-bit domains and every CRC16-bit input are independently checked against Python integer arithmetic. The actual registered conversion pipeline is also exercised for all 65536 raw values, with independent CRC and quotient expectations.

out_error:0success,1invalid static configuration/address/repeatability,2write-address NACK,3command-byte NACK,4read-busy retry exhaustion,5temperature CRC failure,6humidity CRC failure,7abort,8physical I2C failure. If both CRCs fail, error5 has priority while out_crc_bad=3 preserves both causes. out_phy_error preserves shared PHY codes (3stretch-timeout,4arbitration,5busy/stuck,8unsupported). A physical failure releases both low enables and supersedes a pending logical error. Invalid descriptors produce a held error1 response without touching the bus.

Abort during an active byte waits for its bounded physical completion, then attempts STOP and emits error7; physical failures can supersede it. Abort during measurement/retry wait emits STOP/error7. At conversion-completion boundary abort wins over success. Abort never withdraws a response already visible. Aborting an in-progress sensor measurement does not cancel the sensor's internal conversion or issue a sensor break command; a later descriptor might NACK until the sensor is ready. No rollback is claimed.

Synchronous active-low reset overrides CE, clears the response and internal state, and releases the shared PHY low enables on its clock. It may interrupt an I2C operation; the real sensor can remain busy afterward. Caller controls sensor recovery/power-up. Parameter guards: CLOCK_HZ1M..100M, HALF_PERIOD_CYCLES>=4, STRETCH_TIMEOUT_CYCLES>=4, waits/gap1..1000000us, READ_ATTEMPTS1..65535, and all calculated cycle counts fit32bits. Invalid settings report error1 on a request rather than silently aliasing to another mode.

## Verification

Run from repository root with python -B:

    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/run_tests.py
    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/test_errors.py
    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/test_numeric.py
    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/test_parameters.py
    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/test_protocol.py
    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/test_boundaries.py
    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/test_pipeline.py
    python -B cores/system/common_scaffold/peripherals/sht3x_sensor/synth.py

The independently scripted device watches physical SCL/SDA only and checks every address/command/data/ACK/STOP. Tests cover both addresses/all repeatabilities, randomized nonconstant values, busyNACKs and exact attempt counts, first/default measurement and retry wait timing, all raw endpoints, dual CRC faults, NACKs, CE0 request/snapshot/continued acquisition/standard output transfer, held responses, reset, bounded bus busy/stretch, arbitration and fresh-request recovery. All65536 raw inputs verify both numeric conversion helpers and CRC against Python oracles. Fifteen static/command-invalid profiles never issue an I2C transaction.

Complete controller plus reused PHY isolated Gowin synthesis runs three genuine configurations with -nodsp and check -assert, saving full logs and hashes. Resource totals use the final design-hierarchy primitive table so PHY is included. These are isolated fit estimates only; no routed timing, real sensor, combined library or board acceptance is claimed. All HDL/vector/netlist products use automatically removed C: temporary directories; retained source/evidence/log files are small. Existing modules, registry, audit scripts and board artifacts remain untouched.

Timing repair (2026-10-19): the prior one-cycle multiplication/rounding/division/offset conversion failed the complete 50MHz board-wrapper timing target. Full prior RTL, freeze, reports and tests were archived unchanged in sibling sht3x_sensor_before_pipeline_20261019_230154. Conversion now advances through CRC check, registered 8-bit low/high constant products, registered product sum and rounding, registered quotient/remainder decomposition, registered exact remainder correction, then registered signed offset and response. Numeric results, raw outputs, CRC flags, error codes, interfaces and shared physical I2C engine remain unchanged. Conversion success adds five clocks; acquisition continues with CE=0 as before. Abort/reset are checked at every new stage. This is a full-function timing repair, with no raw-only bypass. Original 58 profiles plus 12 stage lifecycle profiles pass; numeric testing additionally checks every value through the actual pipeline. Complete isolated synthesis small/default/maximum uses 1482/1537/1485 LUT-class cells, zero DSP and zero BRAM9. Board route/functional results are owned by the separate full wrapper and are not implied by these isolated reports.

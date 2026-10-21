# MPU6050 coherent raw IMU acquisition

`mpu6050_imu.sv` reads the MPU6050 over I2C at 0x68 or 0x69 (AD0). Every command checks WHO_AM_I register0x75 for exactly0x68; AD0 does not change that register's hard-coded ID. A successful acquisition returns seven signed16-bit raw words in wire order: acceleration XYZ, temperature, angular-rate XYZ. There is no DMP, attitude fusion, image stabilization algorithm, physical-unit conversion, analog calibration or real-device validation claim.

The accepted `ce && start_valid && start_ready` edge snapshots AD0, `configure`, divider, DLPF and range inputs. The sensor must already have stable power/clock, completed its external power-on/I2C startup requirements and be exclusively owned. Configuration mode supports a sensor at its documented power-on defaults or previously configured by this controller. It does not safely take over an unknown DMP/FIFO/I2C-master/low-power configuration left by other firmware. Resetting the FPGA controller does not reset the IMU.

When `configure=1`, after identity verification the engine writes this exact narrow configuration sequence, one register per complete transaction:

| Register | Value |
|---|---|
| 0x6B PWR_MGMT_1 | 0x01: wake, temperature enabled, X-gyro PLL clock |
| 0x6C PWR_MGMT_2 | 0x00: all accelerometer/gyro axes enabled |
| 0x19 SMPLRT_DIV | snapshotted8-bit divider |
| 0x1A CONFIG | DLPF0..6, EXT_SYNC disabled; reserved7 rejected |
| 0x1B GYRO_CONFIG | FS_SEL0..3, self-test disabled |
| 0x1C ACCEL_CONFIG | AFS_SEL0..3, self-test disabled, high-pass0 |
| 0x37 INT_PIN_CFG | 0x00: clear interrupts on INT_STATUS read, bypass disabled, interrupt output active-high push-pull |
| 0x38 INT_ENABLE | 0x01: DATA_RDY enabled, other interrupt enables disabled |

The physical interrupt output is not used by this core; board wiring must accommodate the configured pin behavior. The engine then waits `STARTUP_DELAY_CYCLES+1` system clocks. Choose the parameter for actual clock frequency and sensor/PLL/filter startup and settling requirements;0 is intended only for a suitably warmed/tested integration, not a promise that wake-up takes one clock. The default2700000 provides approximately100ms at27MHz, and is not a universal time constant.

When `configure=0`, the core still checks identity, then acquires without writing configuration. The integrator must already provide awake, all-axis sampling, temperature enabled, DATA_RDY enabled, INT_RD_CLEAR=0 and compatible exclusive ownership. Configuration input fields are ignored in this mode, including reserved DLPF7.

Freshness and coherence are separate guarantees. The engine first reads INT_STATUS0x3A and discards this potentially stale event. It then polls INT_STATUS until a new DATA_RDY_INT bit0 appears, bounded by `MAX_READY_POLLS` completed polls (the final successful poll is included; the discarded read is excluded). Each read clears the status according to the documented configuration. A timeout returns error6 without reading sensor data. This is a polling-count deadline, not a millisecond deadline; account for bus rate, selected sensor output rate, oscillator tolerance and clock stretching.

After readiness, the core issues exactly one14-byte burst starting at0x3B with13 ACKs and a final NACK. InvenSense's register map explicitly states that internal data updates at the sample rate, while the user-facing register set duplicates it when the serial interface is idle; a burst therefore reads one coherent sampling instant. The core relies on that documented hardware guarantee and never assembles separate axis/byte transactions. If another sample arrives between the status read and burst, the burst can return that newer coherent sample. It does not identify an exact interrupt timestamp, count skipped samples, guarantee successive frames are unique, or implement FIFO loss detection. With some rate/filter choices accelerometer data can repeat while gyro data updates faster. Concurrent external register writers are unsupported.

`result_valid` asserts only after all14 bytes and STOP complete. Seven output words, WHO_AM_I, final interrupt status and poll count remain stable until `ce && result_ready`. A separately held `done_valid/error_code` then requires `ce && done_ready`. Host CE gates handshakes only; physical bus, initialization wait and polls continue under CE=0. Synchronous active-low reset has priority over CE, releases the open-drain bus and clears host state. On errors no result is published; stale output fields must be ignored. A partially applied configuration or cancelled external measurement must be recovered deliberately by the host.

Errors:1 transmitted-byte NACK (STOP attempted),2 wrong WHO_AM_I,3 stretch timeout,4 arbitration conflict,5 stuck/busy bus,6 new-data polling exhausted,8 invalid static parameters or requested reserved DLPF. Physical STOP errors override logical NACKs. No automatic retries, bus-clear, sensor reset, DMP or FIFO support is claimed. All reads use pointer-write/repeated START; configuration writes are explicit single-byte transactions.

The immutable shared transport is `peripherals/i2c_eeprom/i2c_eeprom_phy.sv`, recorded using a package-relative dependency SHA256. `rtl_sources.f` lists only local RTL; add the shared dependency when compiling.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/peripherals/mpu6050_imu/test_transactions.py
python -B cores/system/common_scaffold/peripherals/mpu6050_imu/synth.py
```

The independent physical-pin model decodes addresses, configuration order/values and master ACK placement. It starts with a stale DATA_RDY event and old sensor values, publishes a fresh frame only after the initial clear, and injects a different internal frame midway through the14-byte burst while keeping the user shadow stable. Tests check actual signed words, not constant RTL outputs, and cover AD0, ranges, rates/DLPF, CE/backpressure, snapshots, timeouts, faults, resets and parameter boundaries. Synthesis is isolated and includes the unchanged shared PHY. Public InvenSense register map and Adafruit source were actually fetched; URL/size/SHA/excerpts are in `references.json`. Temporary simulation/download products are automatically cleaned. These are digital simulation/synthesis results, not a physical IMU or board acceptance result.

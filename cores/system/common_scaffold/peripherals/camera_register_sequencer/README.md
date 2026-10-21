# Camera register descriptor sequencer

`camera_register_sequencer.sv` executes an external ROM/descriptor stream using the unchanged shared open-drain byte transport `peripherals/i2c_eeprom/i2c_eeprom_phy.sv`. It contains no sensor initialization tables and makes no claim that a particular camera power-up sequence is correct. The integrator supplies a reviewed table for the sensor revision, clock, supply, reset and desired image format.

The CE-qualified start edge latches seven-bit address (0x08..0x77), protocol profile and register width. Descriptor address is `descriptor_index`; an external synchronous ROM can use `descriptor_valid` when its output is available. A descriptor is accepted only at `ce && descriptor_ready && descriptor_valid`. All descriptor fields are then latched; the provider can change outputs while the transaction executes. FETCH stalls hold no active bus transaction. There is no implicit timeout on an absent descriptor: the provider must eventually supply a descriptor or system reset.

| Opcode | Behavior |
|---|---|
| 0 WRITE | Write one eight-bit value to an eight- or sixteen-bit register subaddress. |
| 1 VERIFY | Read one byte and compare `(read & mask) == (expected & mask)`. A zero mask always passes. |
| 2 DELAY | D+1 system-clock residency cycles in DELAY after acceptance, including when D=0. It runs independently of CE and is not a millisecond field. |
| 3 END | Finish successfully without bus traffic. |

`completed` counts successful WRITE/VERIFY/DELAY descriptors; END is not counted. `MAX_DESCRIPTORS` bounds the number of these non-END operations (1..2147483647). END at exactly the limit succeeds, while any additional non-END descriptor fails with error8. `descriptor_index` remains the index of a failing descriptor, or the END index on success.

**I2C profile:** eight- or sixteen-bit subaddress, MSB first for sixteen-bit addresses, strict transmitted-byte ACK checking, repeated START between the pointer-write and one-byte register read. Final read byte is NACKed.

**SCCB profile:** a narrow two-wire, eight-bit-subaddress transaction profile: writes use ID-write/subaddress/data, reads use STOP after ID-write/subaddress followed by a separate START/ID-read/data/STOP. Ninth bits after transmitted bytes are treated as Don't-Care (high or low accepted); the controller releases the final read ninth NA bit. Sixteen-bit subaddresses in SCCB profile are rejected. The public specification describes the two-wire topology as one master and one target; this implementation uses that exclusive topology. NA logical 1 is obtained by releasing the open-drain pin to a pull-up; an externally forced low is treated as a physical conflict. This profile is not the original three-wire SCCB_E interface and is not a claim that every sensor accepts generic I2C. Since DC bits are not an ACK-presence test, a disconnected target can appear to accept a WRITE; use a sensor ID/readback VERIFY descriptor and appropriate mask. The shared transport's stretch/arbitration/stuck-bus checks are electrical safeguards, not assertions that SCCB itself specifies full I2C multimaster operation. Pull-ups and safe voltage levels remain board responsibilities.

NACK in I2C profile attempts STOP then retries the entire current descriptor up to `MAX_RETRIES` additional attempts (0..255). A VERIFY mismatch retries the whole pointer/read transaction after a successful STOP. Writes are therefore suitable for idempotent register settings; external review is required before retrying side-effect registers. Physical errors (stretch/arbitration/stuck-bus) terminate immediately and are not retried. A STOP physical error overrides a pending logical NACK. There is no autonomous bus-clear sequence.

Errors: 1 ACK failure after retry exhaustion, 2 masked VERIFY mismatch after exhaustion, 3 clock-stretch timeout, 4 arbitration conflict, 5 busy/stuck bus, 8 invalid parameters/address/profile/subaddress or descriptor limit. `retries` is the additional-attempt count for the current/last descriptor and resets when the next descriptor is accepted, including END. `last_read` holds the last wire byte; it is meaningful only with the surrounding sequence status.

Host CE gates start/descriptor/done handshakes, while physical I2C, retry and delay execution continue under CE=0. `done_valid`, `error_code` and status outputs remain stable until `ce && done_ready`. Synchronous active-low reset has priority over CE, cancels the sequence and releases the bus. It does not reset the camera. Recovery after reset and sensor-specific reset delays belong in the supplied sequence and board control logic.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/peripherals/camera_register_sequencer/test_transactions.py
python -B cores/system/common_scaffold/peripherals/camera_register_sequencer/synth.py
```

The physical-pin model decodes bus bytes independently of DUT state, implements eight/sixteen-bit pointers and byte register storage, drives SCCB DC high/low, and injects NACK, mismatch, stretch and electrical faults. Synthetic descriptors test sequencing only; they are not unverified sensor tables. Evidence is isolated simulation and Gowin synthesis, with no real sensor or board acceptance claim. `references.json` records actual retrieved public SCCB specification and Espressif driver hashes/excerpts; no third-party RTL is copied. `dependency_sha256.json` uses package-relative shared-PHY paths; `rtl_sources.f` lists the local RTL only. Temporary HDL executables and downloads are not retained.

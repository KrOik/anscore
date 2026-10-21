# Frame-level automatic exposure controller

`img_ae_controller.v` is a synthesizable controller for exposure lines and Q8
gain (256 = unity). It consumes completed frame statistics; it does not collect
pixels or program a sensor. A camera-control bridge must apply each accepted
update at a safe frame boundary and associate later statistics with the applied
settings. This is additional IP, independent of the 48 accepted public entries.

## Interface and transaction contract

All transfers require `clk_en && valid && ready`. `rst_n` is asynchronous low.
CE pauses state, valid and payload; ready is low while CE is low. There is one
transaction in flight; output backpressure blocks both stats and configuration.
The output payload remains stable until accepted. Apply external camera writes
only on the output transfer, not by continuously observing the output registers.

Stats are `stats_luma_sum[47:0]`, `stats_count[31:0]`,
`stats_saturated[31:0]`, `stats_frame_id[31:0]`, `stats_overflow`, with
`stats_valid/stats_ready`. Luminance is unsigned 16-bit, in the same units as
`cfg_target/cfg_deadband` (8-bit luminance may simply be zero-extended).
`stats_saturated` is the count above the collector's saturation threshold;
`cfg_saturation_limit` is an absolute allowed pixel count, not a fraction.
Adjust it when frame size changes. Inputs are snapshotted on transfer.
Existing AWB RGB statistics have a compatible 48-bit sum and 32-bit count
convention, but lack luminance/saturation statistics and cannot be directly
substituted. The separate luminance collector supplies these fields.

Configuration is accepted only when idle and takes priority over stats. The
complete bundle commits atomically: target/deadband, attack/release shifts,
exposure/gain bounds, maximum exposure/gain steps and saturation-count limit.
Zero target, deadband >= target, zero minimum or step, and reversed bounds are
rejected with `cfg_error`; all prior settings and actuator values remain intact.
`cfg_error` is a one-enabled-cycle pulse. Valid configuration clamps current
actuators to new ranges and emits an update tagged `FFFFFFFF`. This tag is a
configuration notification; clients should reserve it in their frame numbering.
Reset starts unconfigured, exposure=1, gain=256, and cancels pending work.

Output is `update_valid/update_ready`, `exposure_lines[15:0]`, `gain_q8[15:0]`,
`measured_mean[15:0]`, `update_frame_id[31:0]`, `update_error`. Invalid statistics
(overflow flag, count zero, saturated count > count, or sum > count*65535) emit
an error update with unchanged actuators and measured_mean=0. No division by zero
occurs. Frame IDs pass through unchanged. Error updates must not program the
sensor. Config changes update the actuator registers immediately but remain
pending on the handshake until consumed.

## Integer control law and precision

Mean = floor(sum/count), using a 48-cycle restoring unsigned divider and a
33-bit remainder. A valid sum fits 48 bits: (2^32-1)*(2^16-1) < 2^48. The
maximum-sum check is exact 48-bit `(count<<16)-count`. A mean is therefore <=65535.
Processing latency is 49 enabled edges after stats acceptance; stalls add time.

If saturated count exceeds its limit, decrease exposure even if mean is dark.
Otherwise decrease above target+deadband, increase below target-deadband, or hold.
For a change, error magnitude is abs(mean-target), except a saturation-driven
change uses at least 1. Raw step is max(1, floor(error / 2^shift)), with attack
shift for decreases and release shift for increases. Clamp separately to the
configured exposure and gain maximum steps and the remaining actuator range.
Exposure moves first; gain moves only on a later frame when exposure is already
at the corresponding boundary. Both are monotonic in the requested direction.
No intermediate wraps: comparisons, distances and actuator-room arithmetic use
17 bits; the mean/deadband comparison is widened. Shifts are 0..15.

This bounded proportional actuator-step law avoids a large ratio multiplier and
uses deadband to settle in the tested model. It does not promise convergence for
arbitrary high sensitivity, noise, delayed frames or quantized sensors. Integrators
must tune steps/shifts/deadband for their sensor and account for sensor write and
frame latency; there is no built-in multi-frame delay compensation or flicker
avoidance. Gain units are Q8 but a downstream bridge must map them to the actual
sensor analog/digital gain register convention.

Design reference reviewed by the integration owner:
[libcamera Raspberry Pi AGC](https://github.com/libcamera-org/libcamera/blob/master/src/ipa/rpi/controller/rpi/agc_channel.cpp)
(target brightness, gain/exposure limits, filtered response). This implementation
is independently written integer RTL, not a reproduction of that camera pipeline.

## Reproduce

From repository root:

```powershell
python -B cores/system/common_scaffold/image/auto_exposure/run_tests.py
$env:PATH="$PWD/tools/oss-cad-suite/oss-cad-suite/bin;$PWD/tools/oss-cad-suite/oss-cad-suite/lib;$env:PATH"
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/auto_exposure/img_ae_controller.v; synth_gowin -top img_ae_controller -noalu -nolutram; stat"
```

`run_tests.py` is a standalone Python integer reference with generated stimuli
for the committed SV testbench. Temporary simulator binaries/includes are removed
automatically. It verifies 2099 frame updates including random 48-bit division,
range exhaustion, saturation, invalid statistics/config, snapshotting, output
backpressure, CE pauses and reset cancellation. Four noiseless, zero-delay linear
sensor scenarios use `floor(radiance * exposure * gain / 256)` clipped at 65535;
dark/bright steps and gain-required illumination settle inside 125..131 for target
128, then remain unchanged for 20 frames. These are specific model checks, not a
claim of physical-camera image quality or general control stability.

Current evidence: `test_result.json` PASS, `synthesis.log` CHECK 0 problems.
Isolated Gowin generic mapping: 1906 LUT1..4 + 305 MUX2_LUT5, 422 FF, no DSP/BRAM.
No placement/routing, clock signoff, JTAG burn or physical sensor test performed.
The controller has wide comparisons/additions; synthesis size alone does not
establish 50 MHz setup/hold. Parent integration owns shared manifests and runners.

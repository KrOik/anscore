# HX711 24-bit ADC acquisition interface

`hx711_adc.sv` implements the HX711 digital serial acquisition, gain/channel selection and explicit power control. It reads signed24bit two's-complement samples without offset-binary conversion. This is a raw ADC interface: calibration, tare, averaging, weight conversion, analog settling and RATE pin control remain application responsibilities. The actual AVIA datasheet was downloaded and parsed; `references.json` records the PDF URL/SHA and `datasheet_excerpts.txt` preserves extracted text. No PDF or third-party RTL is retained.

## Requests, labels and output queue

A request handshakes on req_valid/req_ready. req_mode0/1/2 selects **the next conversion** as A128/B32/A64 by generating25/26/27 pulses. The result's out_mode labels the current, previously selected conversion; out_next_mode echoes the new selection. The first sample after startup/recovery is A128. Mode3 is invalid and generates an error packet without clock pulses or changing the remembered ADC mode. Each valid request waits for one data-ready event, reads24 bits and emits the extra selection pulses. No free-running requests are synthesized.

Each FIFO result contains out_data(signed24), out_mode(2), out_next_mode(2), out_error(3), out_sequence(32). Errors:0 success,1 invalid mode,2 ready timeout,3 active abort,4 active power-down interruption. Error packet data is zero. Sequence starts at0 and increments on every accepted request, wrapping modulo2**32; gaps identify discarded results. accepted_count, completed_count, dropped_count and timeout_count are unsigned32bit saturating counters reset only by rst_n. Completed includes success and all errors, even when their packet is dropped.

FIFO_DEPTH is2..16. Acquisition never waits for output capacity: a completed packet enters the queue if space exists, including a simultaneous pop; otherwise the newest packet is dropped and dropped_count increments. Existing packets remain ordered and unchanged. Error packets follow the same drop policy. req_ready does not depend on FIFO space. A held output remains stable until out_valid/out_ready handshake or reset. Queue outputs are consumed even with ce=0, power_down asserted or abort asserted; these controls do not cancel already published results.

`ce` gates only new request admission. Once accepted, readiness timeout, every SCK edge and packet publication proceed independently of ce and out_ready. busy indicates acquisition or startup/power control, not unread queued data; requests may be admitted with queued results. powered_down indicates the commanded PD-high hold state, including its minimum-duration entry interval, rather than measurement of the analog chip's sleep state.

## Physical timing and recovery

DOUT readiness passes through two synchronizer registers. After synchronized low, the controller requires READY_GUARD_NS before raising SCK. A short high in this guard returns to readiness waiting; an accumulated wait deadline prevents glitches from restarting the timeout forever. DOUT data is sampled directly at the end of each normal SCK high interval: the datasheet permits100ns from SCK rise to valid data, and every supported high interval is at least200ns. This timing assumption must also hold for board delay and FPGA input setup. There is no asynchronous coefficient-memory state or generated internal clock domain.

Normal high and low intervals are fixed clock counts rounded up from nanoseconds. Normal high is strictly below50us and cannot be extended by CE, FIFO fullness, host backpressure or ready timeout. PD_SCK is low while waiting for readiness. Explicit reset, active abort or power_down intentionally holds PD_SCK high for POWERDOWN_US (>60us), then low for WAKE_US. That physical power cycle establishes the known A128 reset mode. A short power_down input pulse still completes the full minimum hold; a held input keeps SCK high indefinitely. Releasing power_down restarts conversion. Startup and controller reset deliberately perform this same physical recovery, rather than assuming an unknown ADC channel after an FPGA-only reset.

Abort of an active request publishes error3 and resets the ADC through deliberate power-down; abort while idle or while only published packets remain does nothing. power_down interrupts active acquisition with error4; entering power-down while idle produces no packet. These events have priority over sampling/normal completion at that clock. Partial samples are discarded, so no incorrect channel label is published. Explicit recovery may extend an already high normal pulse into an intentional >60us power-down; it is not a normal acquisition pulse. Reset drops the queue, in-flight work and counters. Reset must remain asserted for a system-clock edge.

HX711's analog settling after power-up, channel or gain changes can be400ms at10SPS or50ms at80SPS. WAKE_US is a digital low guard, not an analog settling certificate. The controller faithfully labels and returns raw conversions; callers must apply datasheet settling/discard policy before treating values as stable weight measurements. READY_TIMEOUT_US must cover the selected data rate and settling. Datasheet Fig.2 appears to label the third waveform CH.B Gain64, while its authoritative Table3 specifies CH.A Gain64; this implementation follows Table3.

## Parameters and checks

CLOCK_HZ1MHz..250MHz; SCK_HIGH_NS200..49000; SCK_LOW_NS200..1000000; READY_GUARD_NS100..1000000; POWERDOWN_US61..1000; WAKE_US1..1000000; FIFO_DEPTH2..16. READY_TIMEOUT_US is positive and its rounded clock count must fit32bits. A high-time rounding configuration reaching50us is rejected. Defaults:50MHz system clock,1us high/low,200ns ready guard,1s ready timeout,80us PD,10us WAKE and FIFO4.

```powershell
python -B cores/system/common_scaffold/peripherals/hx711_adc/run_tests.py
python -B cores/system/common_scaffold/peripherals/hx711_adc/run_synthesis.py
```

`hx711_device_model.v` is an independent pin-edge device, with asynchronous conversion readiness,80ns data propagation, actual25/26/27-pulse next-selection decoding and >60us power-down detection. A separate host scoreboard checks signed boundary patterns and all modes, sequencing and FIFO retention/drop counts. Five profiles span1/10/50/250MHz, minimum200ns highs/lows, longest49us normal high and FIFO2/3/4/7/16. They cover CE0 during acquisition/output, FIFO-full continued physical clocks, invalid descriptors, timeout/no clocks, readiness glitches, abort during high and while waiting, active/idle power-down and reset recovery. Sixteen invalid parameter configurations are rejected, including32bit timeout overflow.

Actual isolated Gowin synthesis/check-assert passes: default720 LUT-class and largest declared configuration757 LUT-class; both0DSP/0BRAM. The LUT count includes16 RAM16SDP4 distributed-memory primitives at4LUT equivalents each. Full synthesis logs and their SHA are retained; large temporary simulator/netlist files use automatically cleaned C: directories. These results establish digital simulation and synthesis, not board operation or timing closure at250MHz. Shared registration and board integration are parent-owned.

# Continuous PWM / pulse / period measurement

`pulse_measurement.sv` measures a real asynchronous input pin, producing an
atomic active-width / inactive-width / period tuple for each complete cycle.
It supports PWM duty measurement, RC servo pulse capture and tachometer period
measurement. Caller calculations are `frequency = clk_hz / period` and
`duty = high / period`; this is one measurement core, not a second frequency IP.

Repository review found existing `ips_timer4_pwm_cap` with a shared 4-bit width
counter and watchdog fixed to 3 enabled clocks, and `ips_glitch_detector` with
configurable pulse-width min/max monitoring. Those are real existing cores.
This implementation adds wide complete-cycle measurement, independent physical
timing, atomic streamed results and explicit output queue overflow. Existing
implementations remain untouched; see `../gap_audit/REPORT.md` for evidence.

## ABI and configuration

Parameters: `COUNTER_W=32`, legal 16..48; `FILTER_W=8`, legal 1..16.
All intervals are unsigned counts of physical `clk` periods. There is no tick
prescaler; use a suitable clock frequency or scale results in the caller.
`rst_n` is synchronous active-low and overrides CE.

`start_valid/start_ready` with CE=1 captures:

- `cfg_active_high`: physical high is active if 1, physical low if 0.
- `cfg_filter[FILTER_W-1:0]`: require N consecutive synchronized samples of a
  changed level. Values 0 and 1 both accept the first changed synchronized
  sample; N>1 rejects excursions shorter than N sampled clocks.
- `cfg_timeout[COUNTER_W-1:0]`: no-qualified-edge timeout in physical clocks;
  0 disables it.
- `cfg_min_high/cfg_max_high/cfg_min_low/cfg_max_low[COUNTER_W-1:0]`: inclusive
  limits for active and inactive width. Minima must be nonzero and maxima must
  be at least the corresponding minima. Set min=1, max=all-ones to disable
  application range restrictions.

Illegal parameter profiles or runtime limits return DONE/error 1 without
starting measurement. All configuration is captured; changing input fields
while busy has no effect. Start snapshots the current synchronized pin level;
an input already active at start is not treated as a synthetic rising edge.
The first subsequently observed active transition acquires cycle phase.

`input_pin` continuously passes through two clocked synchronizer registers,
followed by the symmetric stable-N filter. Both synchronizer registers carry
an ASYNC_REG attribute. Every physical clock advances this frontend and the
measurement, including CE=0. `busy` covers acquisition and abort drain.

## Results, bounds and recovery

The output stream transfers only on `CE && m_valid && m_ready`; READY and
VALID are not an ungated AXI interface. Outputs are:

- `m_high`: active width, even when active polarity is physical low.
- `m_low`: inactive width.
- `m_period`: active+inactive width.
- `m_is_cycle`: 1 for a completed pair of intervals; 0 for an acquisition
  timeout or interval-counter overflow event.
- `m_flags[2:0]`: bit0 timeout, bit1 overflow, bit2 range violation.

A healthy cycle has is_cycle=1, flags=0. An active transition starts a cycle;
the next inactive transition captures active width, and the next active
transition atomically publishes all three widths and begins the following
cycle. There is no pairing of widths from different acquisition epochs.

An interval can represent 1..2^COUNTER_W-1 clocks. A longer interval reports
is_cycle=0 / overflow=1 with zero widths and loses acquisition. If both
individual widths fit but their sum does not, the completed tuple retains
both widths, saturates period to all-ones and sets overflow with is_cycle=1.
Out-of-range completed tuples retain measured widths and set bit2; they are
not silently discarded. Check flags before calculating an application result.

Timeout measures absence of **qualified filtered transitions**, including the
initial wait for acquisition. A transition exactly at the configured timeout
deadline takes precedence. Timeout or interval overflow emits one event,
loses cycle phase, and suppresses repeated events while the pin remains
unchanged. A subsequent qualified transition re-enables the timer; only a
new active transition acquires complete-cycle phase again. With timeout
disabled, a stuck pin eventually reports interval overflow. No fabricated
zero-frequency or stale prior cycle is reported as a healthy measurement.

## Output queue and stopping

Two FIFO entries bound host buffering. The exposed token remains stable until
host acceptance, regardless of CE, later physical edges, timeout, abort or
other queued results. If both entries are occupied and no simultaneous pop
occurs, the newly completed event is discarded. `drop_count[31:0]` saturates
and `drop_sticky` latches; both count all dropped events, including fault
events. They reset only on reset or a newly accepted start. The measurement
frontend continues running. An internal one-clock event registration stage
feeds the FIFO; it is not a third host-visible retained queue entry.

CE-qualified `abort` stops acquisition and sets terminal error 3. All already
generated/queued/exposed events drain before `done_valid` asserts, so abort
can wait indefinitely for host acceptance. Abort under CE=0 is ignored.
`done_valid/error_code` then hold until CE-qualified `done_ready`; a new start
is accepted after acknowledgment. This continuous instrument ends through
abort rather than a descriptor sample-count limit. Reset alone may cancel
queued output immediately and returns to idle on the reset clock.

## Sampling resolution and verification

For ideal digital edges, the two synchronizer stages add common latency and
the filter adds common qualification delay. Accepted transition timestamps
are quantized to the clock grid, so individual width/period error is less
than one clock period when both edges are retained by the symmetric filter.
The filter deliberately suppresses narrow sampled excursions and can merge
them into a longer active/inactive interval. Pulses not sampled cannot be
recovered. Real analog metastability can add uncertainty; simulation cannot
establish its probability or MTBF. Device placement, synchronizer constraints
and electrical validation remain integration work; no board claim is made.

```
python -B cores/system/common_scaffold/peripherals/pulse_measurement/test_case.py
python -B cores/system/common_scaffold/peripherals/pulse_measurement/test_measurement.py
python -B cores/system/common_scaffold/peripherals/pulse_measurement/test_boundaries.py
python -B cores/system/common_scaffold/peripherals/pulse_measurement/test_protocol.py
python -B cores/system/common_scaffold/peripherals/pulse_measurement/test_parameters.py
python -B cores/system/common_scaffold/peripherals/pulse_measurement/test_quantization.py
python -B cores/system/common_scaffold/peripherals/pulse_measurement/synth.py
```

CASE checks high=9 / low=14 / period=23. Nine measurement profiles compare
actual pin-driven outputs to an independent accepted-transition timestamp
oracle, covering 32/48-bit counters, reversed polarity, filtered glitches,
inclusive range limits, bounded queue drops, CE-off physical measurement,
timeout priority and timeout recovery. Boundary profiles actually simulate
16-bit interval overflow, a complete 80,000-clock period overflow, idle
overflow, filter thresholds 1/255/65535, and relocking after faults.
Protocol tests hold exposed tokens across abort and CE-off drain, test reset
and invalid runtime limits, and prove only one stuck-pin timeout event.
Four illegal static profiles return explicit errors. Six asynchronous edge
phases include both sides of a clock sampling boundary and independently
check the quantized widths and less-than-one-clock digital error bound.
No test forces internal counters or derives expected values from DUT outputs.

Isolated Gowin synthesis (`-nodsp; check -assert`) measures 483 LUT-class cells
at counter16/filter1, 878 at counter32/filter8, and 1256 at counter48/filter16;
all profiles use 0 DSP and 0 conservative BRAM9. These are pre-route estimates,
not clock-frequency, physical synchronizer or board verification results.

`references.json` records actual downloaded Pico SDK duty-cycle measurement
example and ZipCPU UART asynchronous-input synchronization source SHA256,
bytes and excerpts. They informed measurement/sampling boundaries, not copied
RTL. Fetches are memory-only; simulations, vector files and synthesis
intermediates use cleaned C: TemporaryDirectory paths. Retained logs and JSON
evidence are small. Existing source freezes and baseline artifacts are intact.

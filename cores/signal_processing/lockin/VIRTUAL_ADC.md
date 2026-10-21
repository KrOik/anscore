# Clock-scheduled four-channel digital stimulus

`virtual_adc4.v` produces four signed16 lanes at fixed core-clock intervals,
using a synchronous cosine ROM and independently configured amplitude and phase
offset per lane. The phase advances at each scheduled tick,including dropped
samples. Scaling is arithmetic-floor(amplitude*cosQ15/32768);amplitude0..32767.
The first tick uses phase0. Commands latch all parameters;log2N4..12 and
period>=4clocks are required. This is a digital synthetic source,not an ADC model
with analog noise,aperture,clock-jitter or front-end effects.

Unmodified sys_timestamp64 supplies a free-running common clock count. Each
scheduled tick captures that count;all four lanes carry the same timestamp.
ROM/scaling/elastic-buffer latency does not change the recorded sampling time.
Completion waits until the last queued sample is accepted. Start/completion use
held handshakes;reset aborts the source and clears the timestamp epoch.

Ticks do not wait for consumer ready. One-vector storage holds its data and
timestamp under backpressure. If another sample reaches a full buffer,the new
sample is dropped,error bit1 becomes sticky,and dropped increments. generated
counts sampling events;accepted counts output handshakes. At drained completion,
generated=accepted+dropped. Error bit0 rejects invalid commands. Any replay
controller must reject overflowed measurements and abort/reset its incomplete
lock-in block;it must not wait for missing samples or report them as successful.

`test_live.py` connects the actual source directly to lockin4,with no software
timestamp injection. Evidence `live_20261020T192530361459Z` PASS:

- 3complete blocks,4lanes,768vectors,periods4/16/37clocks.
- Every generated sample matches independent integer amplitude/phase/LUT math.
- Every accepted timestamp equals the simulated common-clock value at its
  originating tick;exact period and first/last result timestamps checked.
- I/Q exact;12amplitude/phase error rows in CSV/JSON,limits unchanged from SPEC.
- Forced blocked output retains the first vector,counts16events/1accepted/
  15dropped,flags overflow,then completes after drain;invalid period rejected.

The first two test artifacts are retained: completion ACK in the testbench
failed to span a rising edge after wait(done),so the next start timed out.
Holding ACK across an edge fixed the harness;RTL/golden were unchanged.
These are clock-accurate simulations,not physical frequency or board error tables.

Command: `python cores/signal_processing/lockin/tools/test_live.py` after scripts/env.ps1.
Next: replay-controller abort/recovery,CSR parameter/result protocol,board
synthesis/P&R,physical four-lane controlled replay and hard-JTAG/LA evidence.

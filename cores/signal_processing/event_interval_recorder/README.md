# Real-time event interval recorder

`event_interval_recorder` measures the physical clock interval from the latest
reference pulse to every observation pulse. It can record multiple observations
per reference, distinguish no-reference/expired observations, and stream ordered
measurements through a bounded FIFO. Time and reference history advance despite
output backpressure. Session completion reports observations lost to FIFO overflow.
This supports synchronized trigger/return acquisition, event phase monitoring and
clock-resolution time-of-flight processing; callers convert ticks using their
actual reference clock.

This adds two-event timing beyond the existing single-input PWM/period instrument,
triggered waveform buffers, backpressured timestamp insertion and ordered stream
latency observer. It does not duplicate those capture/measurement functions.
The upstream/reuse review is in `SOURCES.md`.

Current status is **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**, for the finite
checks in `QUALIFICATION.json`. LINT_PASS means Icarus syntax checking here.
No synthesis, PnR, STA, board measurement, device-fit or PPA work was run.

## Clock, event and interval semantics

All signals share rising-edge `clk`. `reference_event` and `observation_event`
are already synchronous one-bit event indications, each representing at most one
event per clock. Holding an event high represents an event on every high clock;
the module does not edge-detect a sampled level. It contains no synchronizer,
pin frontend, subclock time interpolator, analog model or CDC. There is no CE.

`rst` is synchronous active-high and dominates all transfers. It discards the
session and queued results at the reset edge, clears control/counters, and returns
to idle. Ready/valid outputs are gated low while reset is high. FIFO payload RAM
is not cleared; its count hides invalid words until overwritten. Consumers ignore
reset-edge transfers.

For an observation at physical edge O whose latest reference was at edge R,
the successful unsigned interval is exactly `O-R`, with resolution one `clk`
period. Backpressure does not enter that subtraction. A simultaneous reference
and observation is valid interval zero and belongs to the new reference epoch.
Each reference increments an `EPOCH_W`-bit epoch modulo `2^EPOCH_W`, including
references whose observation record is dropped. Epoch0 means no reference only
when status is NO_REFERENCE; epoch0 is also legal after wrap. It is an opaque
modular association identifier, not an unbounded reference count.

The runtime inclusive window is 0..`2^TIME_W-1`. At the exact window boundary an
observation succeeds. The following tick expires the reference; every subsequent
observation remains EXPIRED until a fresh reference. The internal age saturates
instead of wrapping. This also applies to the maximum window: a widened carry
detects expiry beyond the largest representable interval. Window zero admits only
simultaneous reference/observation events. There is no sentinel interval; status
separates a true zero from an invalid record, whose interval is set to zero.

## Session and stream interface

| Parameter | Supported range | Default |
| --- | --- | --- |
| TIME_W | 1..32 | 32 |
| EPOCH_W | 1..32 | 16 |
| FIFO_DEPTH | 1..16, including nonpowers of two | 4 |
| DROP_W | 1..32 | 32 |
| TAG_W | 1..32 | 8 |

Unsupported parameter profiles elaborate a named missing module. All interval,
window, epoch and loss quantities are unsigned integers; no signed arithmetic,
fixed-point scaling, floating point or division is present.

| Ports | Width | Meaning |
| --- | --- | --- |
| arm_valid / arm_ready | 1 each | Start transfer when both high outside reset |
| arm_window | 32 | Full unsigned inclusive interval limit, checked before narrowing |
| arm_tag | TAG_W | Session tag captured on acceptance |
| reference_event / observation_event | 1 each | Physical synchronous events while running |
| stop | 1 | End acquisition on a running edge, then drain |
| busy / running | 1 each | Session owns service / acquisition accepts events |
| m_valid / m_ready | 1 each | Ordered event record transfer when both high outside reset |
| m_interval | TIME_W | Tick interval, zero for invalid records |
| m_epoch | EPOCH_W | Reference association; zero before first reference |
| m_status | 2 | 0 OK, 1 NO_REFERENCE, 2 EXPIRED; 3 never generated |
| m_tag | TAG_W | Captured session tag |
| done_valid / done_ready | 1 each | Completion transfer after FIFO drains |
| done_error | 1 | Invalid arm-window configuration |
| done_dropped | DROP_W | Saturating number of FIFO-overflow observation losses |
| done_drop_saturated | 1 | At least one further loss occurred after the loss counter reached its maximum |
| done_tag | TAG_W | Captured session tag |

Hold all valid arm fields until accepted. Only idle offers `arm_ready`; one
session owns service through completion retirement, with no completion-edge
arm fallthrough. At arm acceptance, window/tag are captured and loss/history/FIFO
state starts fresh. Input events and stop on that acceptance edge are ignored;
the first running edge is the next physical edge. Later arm-field changes have
no effect. A window whose high bits exceed TIME_W is rejected without aliasing:
no acquisition starts and a held completion has `done_error=1`, zero drops and
the captured tag. At TIME_W32 every 32-bit window is representable.

Every running observation attempts to append one result. Observations before a
reference and after expiry still attempt explicit status records. There is no
event ready signal: the source cannot pause physical time. When the FIFO is full,
a simultaneous output retirement frees a slot for that clock's observation;
the new record is admitted without loss. Otherwise only the newest observation
is dropped. Existing records stay ordered and stable, and reference/age state
continues normally. Loss accounting includes all dropped observation statuses.

`done_dropped` saturates at `2^DROP_W-1`. It remains exact when first reaching
that value. A further loss leaves it there and sets `done_drop_saturated`, which
indicates the true count is larger than the reported maximum. Counters and the
flag reset only on a new arm or reset; there is no hidden wrap or midstream
clear. Consumers may see gaps in observation records and must inspect completion
loss diagnostics before treating a session as complete data.

Stop has priority over both events on its running edge; those events are ignored
and are not counted as FIFO loss. Stop then disables new acquisition while all
previously admitted records drain. Events/stop in idle, drain and completion are
ignored. `done_valid` is offered after the FIFO is empty, so it never precedes a
remaining event record. It stays high, with every completion field stable, until
accepted. Output records do not have LAST: the separate completion channel marks
the end of the open-ended session. Reset cancellation intentionally discards
queued data and does not produce a completion/loss report.

The complete valid event bundle remains stable under arbitrary `!m_ready`;
completion behaves likewise under `!done_ready`. A stop is a synchronous control
level, not a ready/valid command. One high running edge is sufficient. `busy`
covers running, drain and held completion; `running` covers acquisition only.

## Architecture, scheduling and resource risk

The design uses a saturating age/window comparison, an epoch incrementer, a
saturating loss counter and one bounded FIFO. There are no multipliers, dividers,
external memories, coefficient tables, generators or vendor primitives. All
production dependencies are the single RTL file. FIFO payload storage is
`FIFO_DEPTH*(TIME_W+EPOCH_W+2)` logical bits: 200 at defaults and at most1056.
Payload writes are synchronous; output selection is asynchronous. Small FIFOs
may map to registers and MUXes; BRAM inference is not claimed. Parameter changes
grow storage linearly and do not unroll event processing.

Qualitative architecture risk is **LOW** for these bounded sizes. The longest
expected paths include the age-limit comparison, full/retirement admission and
FIFO output selection. This is an architecture judgment, not measured area,
clock frequency, DSP/BRAM mapping, power or device fit.

A running edge can observe one reference and one observation simultaneously.
An admitted record becomes visible immediately after that edge if the FIFO was
empty; its earliest output retirement is the following edge. With continuous
observations and ready it can retire one record per clock after initial fill.
Queueing adds one clock per record ahead under always-ready service. A full FIFO
can pop and push on the same clock, including FIFO_DEPTH1. Physical measurement
continues independently even when no output can retire.

After the last queued result retires during drain, completion becomes valid on
the next edge. A stop with an already empty FIFO likewise presents completion
one clock after stop. Invalid-window completion appears just after arm acceptance.
These are RTL clock schedules; unbounded output/completion stalls give no
unconditional session-completion deadline, and no physical-clock performance
measurement is claimed.

## Offline use and finite evidence

Resolve both `files.f` and `example/files.f` from this package root. The example
`trigger_return_intervals` exposes every default port for synchronous trigger and
return pulses. It uses ordinary output ready/valid and does not adapt CE-qualified
ANSCORE streams. The complete source closure is local; no external runtime access
is required.

```text
python -B run_tests.py
```

The runner uses the absolute repository OSS suite paths and prepends its bin/lib
directories. It saves exact executable inputs before any tool/model invocation,
source/tool hashes, all prepared input/expected vectors, raw child output and
per-child status. Each child has a20-second deadline plus bounded tree cleanup.
A missing tool, timeout, child failure or absent simulation PASS marker stops
later launches. Preparation exceptions are recorded as failure; partial syntax
success does not imply a full PASS. `.gitattributes` preserves source bytes.
Ignored `.build/` VVP files await root-owned cleanup after delivery review.

Current finite profiles `(TIME_W,EPOCH_W,FIFO_DEPTH,DROP_W,TAG_W)` are
`(1,1,1,1,1),(4,3,3,3,8),(32,16,4,32,8),(8,32,16,4,32)`. Successful checks
are two syntax compilations, four TB compilations and four simulations. Across
819 simulated stimulus clocks, the TB compared every valid result/control and
completion field and retired324measurement records. The absolute-timestamp/list
oracle admitted328records; four intentionally queued records were cancelled by
reset, explaining that difference. TB output reports233held-result cycles and
180held-completion cycles. Fixture coverage demonstrates full pop+push at all
depths, smallest widths, maximum widths, nonpower-of-two depth, reference/observe
coincidence, exact window limits, elapsed-time expiry past narrow-counter wrap,
epoch wrap at narrow widths, loss saturation at narrow widths, stop priority,
queue/drain completion, invalid high-bit windows, reset and recovery. Model
coverage counts concern the generated fixtures, not internal structural coverage.

The initial simulation failed at reset cycle0 because the independent oracle
left ready high in idle while reset was asserted. The RTL correctly gated it
low. Only oracle ready/valid reset qualification changed; production RTL and
every stimulus file stayed byte-identical. Four expected rows per profile
changed, all reset rows. Original sources, vectors, raw failure and the subsequent
successful run are retained separately; `QUALIFICATION.json` binds both. No RTL
bug, hardware result or exhaustive proof is claimed by this finite suite.

# Timestamp-paced finite event replay

DRAFT / NOT EXECUTED / HW_UNVERIFIED. No simulation, synthesis, PnR, STA,
board, PPA or historical regression has been run for this package.

`timestamp_event_replay` consumes an already ordered runtime stream and releases
its events against an autonomous relative virtual clock. The first accepted
record is the time anchor. Recorded gaps remain relative to that anchor even
when the source is absent or the downstream stalls. Payloads are opaque.

This supplies a missing timing owner, rather than another sorter, deadline
calendar, protocol decoder, matcher, or constant-rate packet shaper. Existing
`ram_deadline_scheduler` uses caller-provided cutoffs; `watermark_event_merge`
establishes safe time order. Neither owns a paced replay clock. Existing
`sys_capture_replay` sends opaque words as quickly as ready allows.

## Parameters and configuration

| Parameter | Default | Legal values |
|---|---:|---|
| TIME_W | 64 | 1..64 |
| DATA_W | 64 | 1..1024 |
| TAG_W | 8 | 1..32 |

All values are unsigned exact bit vectors. Each `c_valid && c_ready` captures
`c_count[31:0]`, `c_step_q16[47:0]` and `c_tag`. Count and step must both be
positive. There are no reserved timestamps, wrap-time ordering, sentinel event,
implicit units, wall-clock synchronization or floating-point conversions.
`c_step_q16 / 65536` is source timestamp units per running clock. The step is
fixed for the whole epoch. The default 64-bit time interface is reduced only by
an explicit static TIME_W parameter; no high timestamp bit is silently removed.

Minimum step is 1/65536 source unit/clock; maximum is
(2^48-1)/65536. Only rates representable in this Q32.16 grid are supported.
For a system that supplies 200 MHz and nanosecond source timestamps, step=5*65536
would represent nominal 1x timing. This is a unit example, not a measured clock
or timing-accuracy claim. The caller selects units and a physically meaningful
rate. Runtime time/count/tag fields are captured only at their own handshakes.

## Stream, time and exact edge phase

`s_valid && s_ready` accepts one `{s_time,s_data}`. Timestamps must be
nondecreasing within an epoch, with equality legal. Equal-time events preserve
input FIFO order. Exactly c_count records are expected; the core accepts no more
than that count. An unbounded missing source has no invented timeout.

The implementation retains one pending record, with a separately latched
output-offer bit. No simultaneous retire/refill or combinational fallthrough is
provided. With continuous input, continuous readiness and already-due records,
accepted events and output retirements have a steady interval of three clocks.
The first output can retire three edges after the command is accepted.

Let A be the rising edge accepting the first event:

1. At A, anchor=s_time, relative virtual time V=0, and deadline=0 are stored.
   No step is added on A. The event is not yet output-valid.
2. At a later RUN edge n, an unoffered pending head becomes offered only when
   run_enable=1 and the **pre-edge** V >= (head_time-anchor)*65536.
3. If that edge is an ordinary nonterminal running edge, V then advances by the
   captured step. Eligibility never uses this edge's new sum.
4. The registered offer is visible after edge n, and can first retire at n+1.
   Thus an always-enabled first event can be offered at A+1 and retire at A+2.

Without pauses and before overflow, pre-edge V at A+k is (k-1)*step for k>=1.
A head already captured in time therefore first becomes eligible on
A+ceil((time-anchor)*65536/step)+1. Its earliest retirement is one edge later.
Source latency, the one-record buffer and output stalls may make it later.
No interval is re-anchored to an earlier output's actual retirement; backlog
may drain every three clocks once its events are already due.

V is TIME_W+16 bits, storing exact fixed-point accumulated steps. The deadline
is the exact unsigned TIME_W subtraction followed by 16 zero bits. A backwards
timestamp is rejected before that subtraction is used. There is no multiply,
divide, rounding or timestamp truncation in the datapath. Integer edge
quantization corresponds to the ceiling above, not cumulative per-gap rounding.

## Pause, reset, abort and output ownership

One rising-edge clock, synchronous high reset, no CE or CDC. `active` is high
in ordinary RUN and overflow-drain ownership, including while paused.

run_enable=0 freezes virtual time and prevents new offers. Input capture and
command/completion interfaces remain live. An already held m_valid remains
valid and may retire while paused. Pause never retracts or alters an offer.
Every output field remains stable while m_valid && !m_ready, except during the
explicit reset/epoch-flush contract below. Invalid output fields are unspecified.

`epoch_flush = rst || (active && abort_run)` is a public combinational qualifier
in the stable window before an edge. It suppresses s_ready and m_valid, so an
abort edge has no apparent data handshake. c_ready is also suppressed by
abort_run. At the accepting edge an active abort cancels the entire epoch,
including a previously held output, freezes old counts/phase and produces
ABORTED completion. The change in held-valid is expressly an **epoch interface
flush**, not an ordinary ready/valid stall. Peers must observe/participate in this
flush and discard any provisional prefix if their transaction needs atomicity.
Reset similarly cancels all current ownership, gates public ready/valid, and
returns to IDLE without a completion. Counters and time are not advanced by a
reset/abort edge. Abort while IDLE or DONE changes no stored transaction; a
held completion is preserved. Completion fields remain stable until d_ready.

## Overflow and terminal priority

The increment uses max(TIME_W+16,48)+1 bits, preserving every high rate bit.
Overflow means the next enabled increment cannot fit V. It is detected before
storing the sum; V freezes at the last representable phase and never wraps.
No new input can transfer on such an edge.

* If no output has been offered, an overflow cancels the pending unoffered
  record and returns TIME_OVERFLOW immediately.
* A held offered event is retained in FAULT_HOLD, unchanged, until retirement.
  Time stays frozen, no new input/offer is allowed, and then TIME_OVERFLOW is
  returned. An offered event retiring on the detection edge is counted.
* A final successful output retirement ends the epoch before a needless terminal
  tick; it returns OK even if another increment would have overflowed. If an
  overflow was already latched while that final output stalled, retirement
  returns TIME_OVERFLOW. An external abort can still flush FAULT_HOLD.

Priority is reset, active explicit abort, final ordinary retirement, new tick
overflow, accepted backwards time, ordinary transfers/eligibility/tick. An
accepted backwards record increments received but is never output; the earlier
prefix remains retired. None of these errors supplies rollback.

## Completion

| d_status | Meaning |
|---:|---|
| 0 OK | All configured events retired |
| 1 BAD_CONFIG | Captured count0 or step0; no event accepted |
| 2 TIME_BACKWARDS | An accepted timestamp is below the previous accepted time |
| 3 TIME_OVERFLOW | Virtual clock could not advance without overflow |
| 4 ABORTED | Explicit active epoch flush |

`d_received/d_emitted` are accepted/retired counts; received includes the
backwards record. `d_anchor` is the first accepted timestamp, or zero before any
accepted event. `d_elapsed_q16` is the frozen relative phase and `d_tag` is the
captured command tag. Fields are defined as a completion only while d_valid.
A held completion blocks a new command. After its retirement the following
edge can accept another command. Standalone recovery after an error needs a new
command; coordinated peers still own disposal of the canceled suffix/prefix.

## Actual strict dual-feed composition

`example/paced_dual_itch_replay.sv` instantiates the unchanged actual
`dual_itch_time_merge` and this new core. It connects m_time64 directly and packs
{feed1,sequence64,payload512} into 577 opaque data bits. Ready is direct
backpressure, not a generated event or bypass. The existing merge's two actual
MoldUDP64/ITCH decoders, keyed deadline service and synchronous RAM are listed
in the complete offline example/files.f. No source copy or protocol rewrite is
introduced. ITCH48 timestamps remain exact zero-extended64.

Original packet/admin/error result channels remain available. The caller must
provide genuine WATERMARK/EOS promises under the existing merge contract; no
watermark is inferred from a packet, heartbeat or timestamp. A source error,
nonzero visible packet status, merge fault, or active external replay abort
poisons this composite epoch until the shared reset. Poison blocks new replay
commands, source configurations and raw packet bytes; it aborts an active pacer
using the public epoch flush. Existing diagnostic/admin outputs keep their
original ownership. Explicit abort also suppresses raw/config acceptance during
its assertion. The shared reset is required before reuse after such a poison.
A replay DONE counts configured events only, not completion of an entire source
session or acceptance of all future packets. Callers separately validate packet
results and the intended replay boundary. A missing promised event can wait
forever without an explicit abort. A new day/wrap/reset requires a coordinated
new timestamp epoch; ordinary unsigned monotonicity is retained.

## Architecture and resource tradeoff

A runtime timestamp-to-cycle divider would add a wide operation and a rounding
policy. The selected virtual-clock accumulator instead keeps absolute relative
deadlines and uses a fixed fractional grid. A one-record FF buffer avoids FIFO
RAM/control at the cost of II3 for already-due events. There is no throughput
requirement justifying a deeper FIFO or duplicated datapath in this first core.

The RTL stores DATA_W+TAG_W+4*TIME_W+184 scalar bits, including binary state,
control bits, count registers, full step, anchor/head time, deadline and phase.
Default is 512 bits; DATA1024/TIME64/TAG32 gives1496 bits. This is a source-level
register-bit budget, not a synthesized FF/LUT result. Data payload is unreset
and becomes reachable only after capture. No array RAM, ROM, vendor primitive,
external memory, DSP operator, multiplier or divider is requested in this core.
The expected long paths are the up-to81-bit increment/overflow decision,
up-to80-bit due comparison and up-to64-bit timestamp difference. Real timing
must be established by tools; no frequency, power or device fit is claimed.
The example's decoder/RAM/merger resources are additional unchanged dependencies.

## Draft verification assets

`prepare_vectors.py` is a finite stdlib-only oracle/fixture generator. It uses
arbitrary-precision completed_ticks*step and ceil(delta*65536/step), rather than
copying the RTL accumulator/deadline datapath. It launches no child and imports
no project module. A fresh exclusive --out directory is required; a failed or
existing attempt is never overwritten. The four named profiles exercise T1/
D1/G1, T9/D37/G5, T64/D577/G8 and T64/D1024/G32. Each case is capped at2048
cycles and each profile at65536 vector rows. A numeric row header, exact row
count, complete field count and EOF fence are checked by the core TB.

Cases include configuration errors, minimum/max step, fractional gaps, equal
order, unsigned sign/extreme timestamps, missing source with running time,
held output, pause, backwards time, abort/reset recovery, reachable narrow-time
overflow including high step bits, overflow-held ownership and terminal-edge
priority. These are finite witnesses, not exhaustive parameter/history proof.

The real wrapper TB drives two complete actual MoldUDP64 packets containing
four ITCH Add events with interleaved timestamps. It checks all decoded payload
bits, feed/sequence, anchored1000-tick offer spacing despite one held output,
packet results, EOS closure, sticky bad-session poison and held-output abort.
It uses external ports only and has a10000-clock cap. Generated packets are
original fixtures, not external captures. Six static parameter boundaries are
planned as explicit expected elaboration rejections.

See PRECHECK_PLAN.json for the single preparation and18 HDL children, each
with a20-second limit and first-failure stop. All source, plan, dependency and
prepared fixture bytes require root plus independent peer exact-source gates
before execution. No command in that plan has been run. Preserve original
failures/timeouts; do not retry, overwrite, reduce traffic, broaden a bound,
force internal state or change an oracle to make a run pass.

## Exact execution gate

The formal unexecuted FINITE_PLAN.json supersedes the command shapes in
PRECHECK_PLAN.json for lifecycle/tool/argv and intermediate fixture-gate binding,
subject to root plus worker_b exact final review before any execution. Numerical traffic,
profiles and limits are unchanged. It specifies19 targets: one isolated
preparation, two syntax checks, four core compile/simulation pairs, one actual
wrapper compile/simulation pair and six expected static rejections. Five images
are retained and each simulation pins its image before process creation.
An expected static rejection keeps its actual nonzero exit and raw FAIL process
record; a separate validated record states that the named rejection is expected.
No failure is rewritten to exit0. The root and independent worker_b must review
all exact final source, dependency, runner, plan and seal bytes and fill the
PENDING SOURCE_REVIEW.json before the one-attempt runner can proceed.

run_checks.py is an independent in-package runner whose lifecycle source is
adapted from the fully reviewed B50 tone-fit/B49 lineage. It never imports any
project helper, oracle or model; preparation executes the archived approved
prepare_vectors.py under isolated Python -I -B. It uses native .git text reads
for the baseline and invokes no Git subprocess. Every target has20seconds
including spawn/PID persistence, one optional tree-termination helper5seconds,
and one final target observation interval2seconds; unconfirmed cleanup blocks
all subsequent launches. The single-use guard and original raw evidence remain
retained on any failure. Normal pinned Icarus ivlpp/ivl driver descendants belong
to the same target budget and cleanup tree. The preparation launches no child.
No runner/model/AST/HDL command has yet been executed for this package.

The final exact review proposes approval of the complete19-target suite and
its explicit preparation-validation code, rather than a manual pause after the
preparation. The runner must persist the preparation's raw terminal record,
validate all seven exact generated files/finite counts, hash/freeze them, and
persist a separate preparation validation record before the first HDL process.
Until root and worker_b accept these exact final bytes, the old draft's
intermediate-gate wording grants no authority to execute anything. After their
acceptance, FINITE_PLAN.json is the controlling lifecycle gate.

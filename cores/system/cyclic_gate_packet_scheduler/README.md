# Cyclic gate packet-launch scheduler

This core buffers packet descriptors in independent FIFOs, cycles through a
runtime gate-control list on real clock ticks, and launches only a head packet
whose complete declared service cost fits the current gate entry. A launch
reserves the shared link for that many clocks. Schedule staging/commit,
time-window guard, packet ordering and non-preemptive reservation form one
bounded service; this is distinct from token refill or visit-based DRR.

Descriptors identify caller-owned packets; packet bodies and the PHY are
outside this core. It is not a claim of IEEE802.1Qbv compliance, PTP time
synchronization or measured Ethernet line rate. One tick is one `clk` period,
and the caller supplies an exact conservative service cost including its own
serialization/overhead. A downstream operation that exceeds that cost is
outside the reservation contract.

## Parameters, clock and reset

`QUEUES=1..8`, `DEPTH=1..16` descriptors per queue, `SLOTS=1..16` cyclic entries,
`TICK_W=1..16`, `DATA_W=1..64`, `TAG_W=1..32`. Defaults4/4/4/16/32/8.
Invalid parameters elaborate a named missing module. Fields are exact unsigned
integers or opaque bits. Durations/costs1..`2**TICK_W-1` are legal, including1
and the maximum. Zero duration/cost is rejected. There is no rounding,
saturation, division, absolute timestamp or wrap-time comparison. Periods may
exceed the tick-field range because the implementation counts each entry
separately rather than summing the period into a narrow register.

All ports share rising-edge `clk`. `rst_n` is asynchronous active-low and
shared with the unchanged canonical FIFOs. It immediately cancels the owned
control response, queued descriptors, active/staged schedule, calendar and
service reservation. The caller must coordinate reset with the downstream
packet launcher: reset does not cancel physical transmission already started.
Release reset synchronously; no reset synchronizer/CDC is included. FIFO RAM
payload is not reset and cannot leak through cleared valid/count state.
There is no public CE. The FIFO's internal CE is tied1.

## Native launch event

`launch` is an **irrevocable synchronous command qualifier**, not a held
ready/valid offer. At a rising edge with rst_n=1 and launch=1, the caller
accepts exactly one descriptor and starts its declared service interval.
`launch_accept` is a same-clock permission from that caller; launch is always0
when permission is0. All inputs must meet clock setup/hold. Launch fields have
meaning only on an edge where launch=1; there is no promise to hold a candidate
while launch_accept=0. This custom contract prevents a previously held offer
from becoming stale when a time gate closes. Do not wire it directly to an
AXI-Stream sink expecting an independently held VALID.

Launch fields are `launch_queue[31:0]`, `launch_cost[TICK_W-1:0]`,
`launch_data[DATA_W-1:0]`, `launch_tag[TAG_W-1:0]`, `launch_slot[31:0]` and
`launch_ticks_left[TICK_W-1:0]`. Tags are copied from ENQ's control tag. A launch
removes that FIFO head and advances the round-robin cursor. Within each queue,
descriptors retain FIFO order. Among eligible open queues, choose minimum
modular distance from the cursor. Closed or non-fitting heads do not block
other queues. A permanently too-long head blocks its own queue until DROP_HEAD,
schedule replacement or reset; there is no implicit fragmentation or bypass.

The pre-edge calendar entry/mask and ticks-left govern an event on that edge.
`cost<=ticks_left` must hold. A launch of cost C on edge n occupies service
ticks n through n+C-1, allowing the next launch no earlier than n+C. Cost1
therefore permits consecutive launches. After a launch, `service_left=C-1`;
it counts down on every clock even if calendar running is subsequently stopped.
A reservation is never preempted by STOP. With correct costs, the guard avoids
crossing the current entry boundary. Adjacent entries with the same open gate
are conservatively treated separately and are not merged into a longer window.

## Calendar and control ownership

Each active entry has a positive duration and QUEUES-bit open mask. START
loads entry0 and its complete duration after its accepting edge; the first
possible launch is on the next edge. Each running edge consumes one remaining
tick. A pre-edge ticks-left of1 still permits a cost1 launch on that edge; after
that edge the next entry and its complete duration become current. The last
entry wraps to0. Empty queues, launch_accept=0, control commands and output
backpressure do not pause the calendar. STOP consumes the current running tick
on its accepting edge and then freezes calendar phase; a later START always
restarts at entry0. All-zero masks are legal closed windows.

Control transfers are ordinary `c_valid&&c_ready` and `r_valid&&r_ready` with
reset released. One control response is owned at a time; there is no
response-retirement/admission fallthrough. The source holds every control
field while blocked. Any accepted command suppresses a launch on that same
edge, including rejected commands. Subsequent scheduling continues while its
response is held. Every response field remains stable under backpressure.
Successful command mutation occurs on command acceptance, not response ACK.

Command fields: `c_op[2:0]`, complete32-bit `c_queue/c_slot`,
`c_duration/c_cost[TICK_W-1:0]`, `c_mask[QUEUES-1:0]`, `c_data[DATA_W-1:0]`,
`c_tag[TAG_W-1:0]`, `c_enable`. Unused fields are ignored for operation checks.

| Op | Action | Used fields |
| --- | --- | --- |
|0 ENQ|Append one descriptor to selected FIFO|queue,cost,data,tag|
|1 WRITE_SLOT|Replace one staging entry; active schedule unchanged|slot,duration,mask|
|2 COMMIT|Atomically copy all staged entries to active, reset phase/cursor|none|
|3 SET_RUN|enable1 starts at entry0; enable0 stops the calendar|enable|
|4 QUERY|Return a captured queue/calendar snapshot|queue|
|5 DROP_HEAD|Discard one queued descriptor without reserving link service|queue|
|6,7|BAD_OP, no mutation|none|

COMMIT requires stopped calendar, zero service reservation and every staged
entry written at least once. Staging writes are allowed during running and do
not affect active entries until a successful COMMIT. Commit preserves queued
descriptors, resets slot/cursor to0, loads entry0 duration, and leaves running0.
START requires an active plan, stopped calendar and zero service reservation.
STOP is accepted even if already stopped or a reservation remains busy.
DROP_HEAD is independent of a packet already launched and can discard only a
still-queued descriptor. It does not reclaim or shorten active service.

Status `r_status[3:0]`:0 OK,1 BAD_OP,2 BAD_QUEUE,3 BAD_SLOT,4 ZERO_VALUE,
5 FULL,6 BUSY,7 INCOMPLETE_PLAN,8 EMPTY. ENQ checks queue, positive cost, then
pre-edge capacity. WRITE_SLOT checks complete slot, then positive duration.
COMMIT checks BUSY before completeness. START checks BUSY before active-plan
presence. QUERY/DROP validate the complete queue before using selected fields; empty
DROP returns EMPTY. Rejections change no queue or plan, while elapsed time and
an existing service reservation continue normally.

Every response echoes operation, complete supplied queue/slot and request tag.
For any valid supplied queue, `r_count`, `r_head_cost/r_head_data/r_head_tag`
capture its **pre-command** occupancy/head, even for non-queue operations or
rejected commands. Empty/invalid queues have zero head fields; invalid queues
also have count0. `r_active_slot/r_ticks_left/r_running/r_busy` capture the
pre-command calendar/service state. These snapshots do not freeze the live
scheduler. Thus ENQ/DROP responses describe state before their mutation.

Live diagnostics `running`, `active_slot[31:0]`, `ticks_left/service_left`,
`gate_mask` and packed `levels` change with clocked state and are not held
transactions. Queue0 occupies the least significant count slice of width
`max(1,clog2(DEPTH+1))`. They have no physical-time accuracy beyond this clock.

## Storage, integration and source checks

One unchanged `cip_sync_fifo` per queue supplies registered heads and synchronous
RAM reads. Source closure lists that canonical file exactly once plus the new
wrapper; no production duplicate is introduced. Descriptor logical storage is
`QUEUES*DEPTH*(TICK_W+DATA_W+TAG_W)` bits (896bits at defaults,14336bits at maximum
settings). The canonical FIFO's RAM/output organization may add a physical
output register beyond logical capacity. Two gate banks use
`2*SLOTS*(TICK_W+QUEUES)` bits (160default,768maximum), plus control/status.
Round-robin eligibility compares at most8 registered heads. No payload packet
RAM, external memory, vendor primitive, multiplier or divider is added.
Qualitative resource risk is LOW at defaults and MEDIUM for maximum mux fan-in
and FIFO packing; actual RAM inference, Fmax, device fit, power and throughput
are unmeasured.

ENQ has a registered FIFO head available after its accepting edge. With an
already fitting head, no reservation, permission and no accepted control,
one launch can occur on the next sampling edge. Eligibility is combinational
over bounded registered heads; this is an RTL schedule description, not a
measured low-latency or market/network line-rate promise. Closed gates, long
heads or caller permission can postpone service indefinitely.

Both `files.f` and `example/files.f` resolve from this package root. The
complete all-port `example/cyclic_packet_gate4.sv` uses default parameters.
Connect launch pulses to a same-clock packet-launch engine honoring declared
service cost, and coordinate reset. Tags/data can identify DMA packet buffers;
the scheduler does not inspect Ethernet framing, FCS or actual byte transfer.

Run `python cores/system/cyclic_gate_packet_scheduler/run_tests.py` from the
repository root. The independent deque/list model emits complete per-clock
input/expected vectors before any HDL check. The runner freezes exact executable
and canonical dependency copies, records hashes/raw streams, and gives each
child a20-second watchdog with process-tree termination and bounded cleanup.
Missing dependencies/failure/timeouts stop later child launches; no automatic
retry or whole-repository regression runs. Complete-plan success and a TB PASS
marker are required. Actual status is in `QUALIFICATION.md`; all hardware is
HW_UNVERIFIED. Ignored task-specific images are retained for root-owned review.

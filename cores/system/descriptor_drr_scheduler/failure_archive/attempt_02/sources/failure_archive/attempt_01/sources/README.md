# Descriptor deficit round-robin scheduler

`descriptor_drr_scheduler` stores multiple opaque descriptors per flow and
services their positive integer costs using deficit round-robin (DRR). A
nonempty flow gains its configured quantum once per visit, may retire several
descriptors during that visit, and retains insufficient credit for its next
visit. Empty flows lose their credit. Credit advances with scheduling visits;
it does not refill with elapsed clocks.

Maturity is determined by the valid, source-matching `verification.json`
receipt: the candidate is NOT_RUN until executed; only a complete PASS of all
24 children establishes **LINT_PASS / UNIT_SIM_PASS**. **HW_UNVERIFIED** always
applies. Preparation and HDL require separate authorization. No synthesis, PnR, STA, board test, PPA or power
measurement, inherited regression or expanded regression is part of this
package's finite qualification.

This service schedules descriptor authorization. It does not store packet
bodies, inspect packet framing, observe actual bytes transferred, or wait for
DMA/bus completion. Byte fairness applies when the supplied costs represent
bytes and output retirement is the service event the caller intends to charge.

## Offline inputs and parameter domain

All source dependencies are local to this directory. `files.f` closes the core;
`example/files.f` adds `descriptor_drr4`, a fixed default wrapper exposing every
port. Python tools use only the standard library. Runtime fixtures do not use
external source, network, generated ROM, include paths or vendor libraries.

| Parameter | Default | Legal |
| --- | ---: | --- |
| `FLOWS` | 4 | 1..16 |
| `DEPTH` per flow | 8 | 1..32 |
| `COST_W` | 12 | 1..16 |
| `DATA_W` | 32 | 1..64 |
| `TAG_W` | 8 | 1..32 |
| `DEFAULT_QUANTUM` | 64 | 1..2^COST_W-1 |

When changing COST_W, also choose a legal DEFAULT_QUANTUM. Derived `PW` and
`CW` are port-width parameters, not independent configuration: they must equal
`max(1,ceil(log2(DEPTH)))` and `max(1,ceil(log2(DEPTH+1)))`. Invalid parameters
instantiate `descriptor_drr_scheduler_invalid_parameters__see_README` and fail
elaboration. The quantum guard compares the full parameter value to a 64-bit
bound before any storage-width conversion.

## Commands and exact commit boundary

All ports share one clock, no CE. `rst` is synchronous and high active.
`cmd_valid && cmd_ready` accepts one operation and captures every field.
The source holds all fields stable until acceptance or reset.

| Port | Width | Meaning |
| --- | ---: | --- |
| `cmd_op` | 2 | ENQ=0, SET_QUANTUM=1, QUERY=2, invalid=3 |
| `cmd_flow` | 32 | Unsigned full index, validated before narrowing/indexing |
| `cmd_cost` | COST_W | Descriptor cost for ENQ; new quantum for SET_QUANTUM |
| `cmd_data / cmd_tag` | DATA_W / TAG_W | Opaque payload/tag; tag also echoed by response |
| `rsp_valid / rsp_ready` | 1 each | One owned response |
| `rsp_status / rsp_flow / rsp_tag` | 3 / 32 / TAG_W | Outcome and exact accepted flow/tag |
| `rsp_count` | CW | Target occupancy immediately before command acceptance |
| `rsp_quantum / rsp_deficit` | COST_W / COST_W+1 | Target values immediately before acceptance |

A successful command commits on the **command-accepting edge**. Holding its
response does not postpone or roll back the operation. All response fields
remain stable under backpressure. No next command is accepted while a response
is owned, including its ACK edge. Scheduling and output retirement can continue
while the response is held. An invalid flow returns zero snapshot fields.
Snapshots precede both the command mutation and any same-edge output retirement
or visit-credit update; QUERY does not freeze the live scheduler.

Status priority is invalid opcode, invalid flow, then the operation-specific
check below. Rejections mutate no queue, quantum or credit state.

| Status | Name | Condition |
| ---: | --- | --- |
| 0 | OK | Accepted legal operation |
| 1 | BAD_OP | Opcode 3 |
| 2 | BAD_FLOW | Supplied 32-bit index >= FLOWS |
| 3 | ZERO_COST | ENQ cost is zero |
| 4 | FULL | ENQ sees DEPTH occupied slots before this edge |
| 5 | BUSY | SET_QUANTUM sees a nonempty target |
| 6 | ZERO_QUANTUM | SET_QUANTUM quantum is zero, checked before BUSY |

Each legal runtime quantum is positive and fits COST_W. Configuration succeeds
only when the target's current count is zero, and clears its deficit. A queue
whose last descriptor retires on the same edge still appears nonempty to this
check. Similarly, a full queue rejects admission even on a simultaneous pop;
there is no full-queue bypass. QUERY returns the same pre-edge snapshot without
mutation, regardless of occupancy.

## Output ownership, pause and reset

`m_valid && m_ready` retires exactly one complete `{flow,cost,data,tag}`. All
fields remain stable while valid and not ready. Count includes the held
descriptor, whose RAM slot and cost remain owned until retirement. Only
retirement advances its head and subtracts its cost. For a same-flow enqueue
and pop, occupancy changes by zero. If that was the old last descriptor, the
new descriptor keeps the flow continuously backlogged and the current visit
continues with its remaining credit. Without replacement, credit becomes zero
and the cursor advances.

`run_enable=0` freezes VISIT/READ/CHECK scheduling progress, permitting paused
preload and configuration. It never retracts an already valid output and does
not prevent its retirement. Commands and responses remain live during pause.
If a held output retires during pause, its head/count/deficit update still
commits; subsequent selection waits for run_enable. This is a scheduling pause,
not a clock enable for the ready/valid interfaces.

Reset drops pending responses and output, discards all queued descriptors,
restores every quantum to DEFAULT_QUANTUM, clears credit and pointers/counts,
and restarts cursor zero. RAM payload and the read register are not reset;
their values are unobservable until a newly admitted descriptor is read.
Reset suppresses cmd_ready and m_valid. No old result survives reset.

## Architecture, bounds and reuse choice

One flattened synchronous 1W1R descriptor RAM stores
`FLOWS*DEPTH*(DATA_W+TAG_W+COST_W)` bits: **1664 default**, **57344 maximum**.
Per-flow head/tail/count/quantum/deficit state totals **140 default**, **784
maximum** bits. There is one head/read register, one cursor, a small FSM and
one response register. These are declaration-level budgets, not synthesized
BRAM/LUT/FF counts. No multiplication, division or DSP datapath is required;
constant DEPTH address scaling is an address decode operation.

Pointers explicitly wrap at DEPTH-1, including DEPTH=1 and non-power-of-two
depths. An accepted write cannot collide with a simultaneous head read: a
nonempty, nonfull ring's tail differs from head; full admission is rejected;
an empty ring cannot already be in READ; empty-to-nonempty admission is noticed
by a later VISIT. A same-edge last pop and write completes before the following
READ, so it does not depend on RAM read-during-write behavior.

VISIT adds one quantum, READ captures the head synchronously, CHECK compares
its cost and HOLD owns the output. After a successful pop, the next READ stays
in the same visit. A failed comparison advances the cursor and retains credit.
Retained credit is strictly less than the unchanged head cost; an empty or
newly configured flow starts at zero. With M=2^COST_W-1, visit-entry D<M and
Q<=M, so D+Q<=2M-1=2^(COST_W+1)-3. The COST_W+1-bit credit never wraps,
saturates or discards fractional credit. All costs and state are unsigned.

An uninterrupted same-flow departure needs READ, CHECK and HOLD retirement,
at least three clocks. A new visit adds a VISIT clock. Insufficient heads may
require multiple visits. Positive quantum guarantees eventual eligibility in
visit count for a persistently queued head, but output stalls have no assumed
bound and there is no unconditional clock deadline or bandwidth guarantee.
Weighted work fairness is scoped to continuously backlogged flows with fixed
quantum. The finite certificates do not establish arbitrary changing-queue
latency. `SOURCES.md` records actual baseline semantic dedup and why direct
reuse of shared_packet_queues would require a separate shadow cost FIFO.

## Frozen finite qualification

The reviewed plan is `TEST_PLAN.json`: five legal elaborations, seven scripted
simulations and twelve named invalid-parameter elaborations, **24 compiler or
simulator children** total. Each entire process tree has a 20-second hard
limit. First failure/timeout is terminal, leaves remaining records NOT_RUN and
never automatically retries or reduces fixtures. Source, plan, tool binaries,
fixtures, logs and receipt hashes are retained.

After the separate preparation authorization, run exactly once:

```text
python -B prepare.py
```

It generates seven deterministic event scripts and independent oracle
certificates, including two fixed 512-retirement continuous-backlog windows.
The pure Python reference uses cyclic queue visits and packet events; it has
no RAM latency, clock-state copy or simulator dependency. Command snapshots,
all output order/data/cost/tag values and reset cancellation are explicit.
Fairness certificates assert exact `served+deficit=visits*quantum`, visit-count
distance <=1, and pairwise weighted-work bounds using the actual <=31 cost
limit of those windows. Every head is replenished before pop so no tested flow
becomes empty during its stated fairness window.

For each script, the finite cycle bound is computed before HDL as
`128 + 12*actions + 8*abstract_head_examinations`. Explicit command/hold/ACK/
reset overhead is <=12 clocks per action, and one abstract examination needs
at most VISIT+READ+CHECK plus alignment, covered by eight. Preparation rejects
bounds above 100000 clocks for max or 40000 for other jobs, without executing
HDL. Exact bounds and hashes are sealed before any compiler starts.

After a separate HDL authorization:

```text
python -B run_tests.py freeze
python -B run_tests.py run
```

The default elaboration also compiles the all-port wrapper. No HDL is invoked
by `freeze`. Later `python -B run_tests.py audit` only rereads hashes and logs;
it never compiles, simulates, regenerates fixtures or reruns the oracle.

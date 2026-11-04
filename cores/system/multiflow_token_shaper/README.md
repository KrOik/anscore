# Clock-quantized multiflow descriptor shaper

`multiflow_token_shaper` buffers one descriptor per flow, replenishes independent
token buckets on real clock quanta, and emits eligible heads in round-robin
order. A flow waiting for credits does not prevent another eligible flow from
being selected. Every input lane has independent ready/valid ownership. Runtime
configuration uses a separate acknowledged control channel.

Maturity: **LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED**. The fixed default
wrapper is **LINT_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. No synthesis,
PnR, STA, board check, PPA measurement or expanded regression was run. This
service schedules opaque descriptors. It neither buffers packet bodies nor
observes actual DMA completion, bus responses, downstream byte traffic or
packet framing. Token charging occurs when a descriptor authorization retires.

## Offline use and representation

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s multiflow_token_shaper -f files.f
iverilog -g2012 -Wall -tnull -s dma_shape4 -f example/files.f
python -B run_tests.py
```

The standard-library runner prefers `IVERILOG` / `VVP`, the workspace OSS CAD
Suite, then PATH. Every compiler/simulator child has a **20-second limit**.
A timeout immediately leaves NOT_RUN evidence and terminates that check; there
is no reduced fixture or timeout retry. An old PASS report is replaced with
NOT_RUN before tools start. Only the complete finite matrix publishes PASS.
Vectors/executables use a temporary directory. No network, sibling source,
include, generated ROM or vendor library is needed offline. `files.f` closes
the core and `example/files.f` adds a fixed default wrapper exposing every port.

| Parameter | Default | Legal |
| --- | ---: | --- |
| `FLOWS` | 4 | 1..16 |
| `TOKEN_W` | 16 | 1..32 |
| `DATA_W` | 32 | 1..64 |
| `TAG_W` | 8 | 1..32 |
| `QUANTUM` | 16 | 1..1024 clocks |

Illegal settings fail elaboration through
`multiflow_token_shaper_invalid_parameter__see_README`. All costs, rates,
capacities, balances, IDs and tags are unsigned integers. `s_data` is opaque
bits. Token units are caller-defined; byte costs and bytes-per-quantum rates
are a possible interpretation. Integer rate/QUANTUM gives the average refill
rate; there is no sub-token rounding, timestamp input or wrap-time assumption.
Every configuration field and descriptor field is captured at its handshake.

## Configuration and its atomic boundary

| Port | Width | Meaning |
| --- | ---: | --- |
| `c_valid / c_ready` | 1 each | Configuration offer/acceptance |
| `c_flow` | 32 | Full-width flow index, checked before array access |
| `c_enable` | 1 | Enable descriptor admission and token refill |
| `c_capacity / c_rate / c_initial` | `TOKEN_W` each | Burst cap, refill per quantum, balance to install |
| `c_tag` | `TAG_W` | Control request tag |
| `r_valid / r_ready` | 1 each | Configuration response/acknowledgement |
| `r_status / r_flow / r_tag` | 2 / 32 / `TAG_W` | Outcome and captured ID/tag |

Status 0 is OK, 1 is BAD_FLOW (`c_flow>=FLOWS`), and 2 is BAD_VALUES. Values
are rejected when initial or rate exceeds capacity, or enable is one with
capacity zero. Status 3 is never emitted. Disabled zero-capacity configuration
is legal if rate and initial are also zero. Rate zero is legal. Responses echo
the complete supplied ID and tag, including errors.

A valid-index configuration offer waits until that flow has no pending or
held descriptor, even if the values are malformed. An invalid flow can be
accepted whenever the single response slot is empty. The source holds valid
and **all** control fields stable until accepted or reset. One response is
owned at a time, and all response fields/valid remain stable under backpressure.
No next configuration is accepted on the current response's retiring edge.

An OK configuration commits **only on `r_valid && r_ready`**. It replaces
enable/capacity/rate/balance together, installing exactly `c_initial`; error
responses change none of these values. The target descriptor ingress is
blocked on the configuration-accepting edge and throughout the held response,
including an error response. Thus a new descriptor cannot enter between the
empty-flow check and the configuration commit. Other flows keep admitting,
refilling and retiring work. A held response leaves the target's old settings
active, so its old enabled bucket may keep refilling. Successful configuration
ACK wins over that edge's refill and installs exactly the saved initial value.
It does not reset the global quantum phase. The target can admit at the edge
after its configuration response retires.

## Per-flow ingress and shared egress

`s_valid` and `s_ready` have FLOWS independent bits. For flow i, cost/data/tag
occupy `i*WIDTH +: WIDTH`; flow zero is the least significant slice. Each
`s_valid[i] && s_ready[i]` edge accepts one complete descriptor. Multiple flows
can accept on the same edge. An enabled, empty, non-configuring flow is ready;
disabled flows and occupied slots backpressure their own lane. The source on
each lane holds its valid, cost, data and tag until that lane accepts or resets.
There is no shared ingress ID or capacity borrowed from another flow.

An admitted cost is invalid when zero or greater than that flow's installed
capacity. It is still owned and queued, then emits BAD_COST without spending
tokens. Its classification is fixed at admission; configuration cannot change
while it remains pending. A positive cost within capacity waits until its
whole cost is available. Partial charging or packet fragmentation is absent.

| Egress port | Width | Meaning |
| --- | ---: | --- |
| `m_valid / m_ready` | 1 each | One descriptor result, transferred on rising edge |
| `m_flow` | 32 | Selected flow index |
| `m_status` | 1 | 0 authorized, 1 BAD_COST |
| `m_cost / m_data / m_tag` | `TOKEN_W` / `DATA_W` / `TAG_W` | Complete admitted descriptor, echoed for either status |

An empty output register selects the eligible pending flow with minimum
modular distance from the round-robin cursor. Eligible means BAD_COST or
pre-edge balance >= cost. A refill occurring on that same edge is visible to
selection at the **following** edge. New ingress similarly becomes selectable
at the following edge. Selection latches the complete output and retains its
per-flow slot; it does not spend tokens or advance the round-robin cursor.

While a result is held, every output field and valid stay stable. Its per-flow
slot remains pending, so neither reconfiguration nor another descriptor can
consume that owner's credits. Refills continue during the hold, which can only
increase its credit balance. At `m_valid && m_ready`, an authorized cost is
charged exactly once, its pending slot is released, and the cursor moves to
the flow after that owner. BAD_COST also releases its slot and advances the
cursor, with no debit. All live descriptors in a flow preserve FIFO order;
there is only one resident item per flow. No same-edge slot replacement or
output fallthrough is provided. A held output blocks all further output
selection, but other empty input slots can still accept descriptors.

The round-robin rule concerns continuously eligible heads and actual result
retirements. It does not promise a wall-clock latency when credits or a sink
are unavailable. In particular, an enabled flow with **rate zero and cost
greater than its initial balance remains pending forever**. Its own configuration
is also blocked by that pending owner. Coordinated reset is the recovery path;
there is no hidden cancellation, waiter queue, timeout or forced reconfiguration.
Other eligible flows can still progress. An offer to a disabled flow can wait
indefinitely for configuration. Callers must account for these conditions.

## Clock, reset and token arithmetic

There is one rising-edge clock and no CE, gated clock or CDC. All public
handshakes are ordinary valid/ready. A legacy CE-qualified stream requires an
explicit adapter. Phase resets to zero and advances on **every** non-reset
edge, including idle time, disabled flows and all source/control/sink stalls.
The edge whose pre-edge phase is QUANTUM-1 is a refill tick, then phase returns
to zero. QUANTUM=1 ticks on every edge. Configuration does not restart this phase.

For each flow at a non-reset edge, use its old enable/configuration and balance:

```text
credit = tokens + (tick && enabled ? rate : 0)
balance = min(credit, capacity)
if authorized egress handshake for this flow: balance -= cost
if successful configuration ACK for this flow: balance = saved_initial
```

The final branch also installs the saved settings. The target cannot own an
egress handshake then because configuration requires it empty and blocks its
ingress. Addition has TOKEN_W+1 bits, preserving the largest `2*(2^TOKEN_W-1)`
sum before clamping. A selected good descriptor has enough old balance;
reservation prevents another debit and refill never decreases it. Therefore
the later debit cannot underflow. Balances stay in 0..capacity without wrapping.

`rst` is synchronous active high and must span a rising edge. It has priority
over configurations, input capture, refill, selection and debit. Ready/valid
outputs are also suppressed combinationally while reset is high. Reset clears
enable, capacity, rate, tokens, phase/cursor, pending ownership, control/output
registers and both held responses. Queued payload bits need no reset because
no pending bit survives; they are overwritten before selection. All flows
start disabled and require configuration. Reset cancels all queued/held work;
coordinate reset with descriptor producers and the downstream payload engine.
Already accepted authorizations or already performed downstream memory work
are not rolled back by this service.

## Timing and structural budget

A configuration accepted on edge E exposes its response after E; it can ACK
on E+1 at earliest. A descriptor accepted on E can be selected on E+1 and
transferred on E+2 at earliest if its old credits suffice and output is empty.
If a tick at E provides missing credits, selection can use them on E+1. With
continuous ready and eligible queues, output transfers are two clocks apart.
After a result retires, its lane may accept again at the following edge. Source
and sink stalls can extend these schedules without changing ownership.

Per-flow storage comprises three token/configuration words, one queued cost,
data and tag, plus enable/pending/bad bits: `FLOWS*(4*TOKEN_W+DATA_W+TAG_W+3)`.
The shared register count is `2*IW+QW+4*TOKEN_W+DATA_W+2*TAG_W+38`, where
IW=max(1,clog2 FLOWS) and QW=max(1,clog2 QUANTUM). This includes the cursor,
held owner, phase, staged configuration, both valid bits and complete registered
control/descriptor outputs. The 32-bit output flow is a zero extension of the
held internal index, not another 32-bit register.

| Declared register state | Default bits | Parameter-maximum bits |
| --- | ---: | ---: |
| Per-flow banks, including one queued descriptor each | 428 | 3,632 |
| Shared configuration/control/output | 158 | 312 |
| Total | 586 | 3,944 |

These are declaration counts, not mapped physical resources. Combinational
next-token wires, eligible bits, priority-selection temporaries and loop
indices are excluded. Refill uses one TOKEN_W+1 saturating add per flow and
eligibility uses per-flow comparisons. A shared modular-rank priority scan
chooses the result; no multiplier, divider, payload RAM, external memory or
vendor primitive is present. The small banks use registers and are not claimed
to infer BRAM. Default qualitative risk is **LOW**, maximum **MEDIUM** because
16 wide credit/eligibility cones and the selected-descriptor mux can constrain
timing. Fmax, device fit, LUT/FF/DSP/BRAM and power remain unmeasured.

## Finite independent evidence

Five FLOWS/TOKEN_W/DATA_W/TAG_W/QUANTUM profiles are checked:
`1/1/1/1/1`, `3/5/7/3/3`, `4/12/16/8/7`, `4/16/32/8/16`,
`16/32/64/32/1024`. The qualified report contains 23 bounded child commands,
including ten named invalid-parameter rejections. Positive stderr is empty.
No child timed out. No fixture was reduced or retried after a timeout.

The independent Python ledger uses unbounded integers at every clock and
separate per-flow FIFO histories. Selection takes an argmin of modular ranks,
not the RTL's procedural wrap/priority scan. The trace checks complete public
interfaces before each edge and every flow's configuration, credits, pending
cost/data/tag/error, global phase and cursor after each edge. Thus withheld
output charges, stale configuration, truncating refill arithmetic, premature
slot release and incorrect tick/ACK priority cannot hide behind final totals.
Source/control hold assertions and complete held output/response checks are
also exercised with real stalls.

The fixed run has **18,969 trace clocks / 1,574 admitted and retired descriptors /
68 configuration responses**, including 717 BAD_COST results and 857 authorized
descriptors. There are 216,908 full per-flow ledger checks and 216,908 queue
checks, 152 observed bypasses of a credit-poor cursor head, 308 simultaneous
refill/debit edges, 10 configuration ACKs on refill ticks and 2,082 sums above
the token word's maximum before saturation. Actual source stalls total 181,290,
control-source stalls 4,282, held egress clocks 8,384 and held control responses
1,177. Refills occur during 1,376 held-owner clocks. Trace counters exclude the
reset/recovery probes and do not claim exhaustive traffic coverage.

**75 immediate reset probes / 75 fresh recoveries** cover idle/disabled state,
pending configuration, ACK/tick priority, actual zero-rate underfunding and
blocked reconfiguration, pending preselection, held good/bad descriptors,
held bad-flow/bad-values/successful control responses, blocked target ingress,
pre/post tick with a held owner, tick plus actual retirement and simultaneous
multi-lane admission. Each observed target calls `reset_now` without another
active edge. Every fresh recovery reconfigures flow zero, admits and holds one
known descriptor, checks no pre-handshake charge, retires it, verifies its exact
balance/cursor/slot state and checks idle clocks for stale output. At singleton
settings some boundaries coincide; these are counts of probes, not unique states.

The initial non-qualified F3 run detected a TB-only reset-release alignment
error. Its failure, old/new TB hashes and exact correction are retained in
`history/initial_alignment_failure.json`, separately from the current qualified
commands. The complete unchanged matrix then passed after driving cycle zero
at the actual reset-release boundary. RTL, oracle, fixtures and timeouts were
unchanged by that correction. This history is not counted as qualified PASS.

All eleven local non-report files are strict UTF-8/LF and SHA256-bound in the
report; dependencies are empty. Tests are deterministic and finite, not formal
proof or a legal-domain theorem. No historical physical evidence is inherited.
All local RTL, wrapper, oracle, tests and prose are original Apache-2.0 work.
`LICENSE` supports standalone offline use; `SOURCES.md` records semantic and
actual fixed-source/full-license preflight.

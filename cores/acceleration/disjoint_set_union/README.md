# Command-oriented disjoint-set union

`disjoint_set_union` maintains a partition of a fixed set of node IDs. It
supports representative lookup, joining two components, connectivity queries,
and restoring all singleton sets. This is a standalone graph/control primitive;
the existing image CCA equivalence tables serve frame-local pixel labeling.

## Interface and command results

All ports use one rising-edge clk. `rst` is synchronous high and cancels the
active command or held response. It starts a complete singleton initialization,
one node per clock after deassertion. No command is accepted until all nodes
are initialized. There is no CE, CDC or implicit enable qualifier.

`s_valid && s_ready` accepts s_op, s_a, s_b and s_tag together. The producer
holds all fields stable while stalled. `m_valid && m_ready` consumes one result;
all response fields and valid remain stable during a stall. A command owns the
core until its result is consumed, preserving order. The next command may
transfer on the edge after the previous result transfers. No frame/LAST marker
applies: each command/result pair is a complete transaction.

| Parameter | Default | Legal range |
| --- | ---: | --- |
| NUM_NODES | 64 | 1..4096 |
| TAG_W | 8 | 1..32 |

Node IDs are unsigned 0..NUM_NODES-1, with
`INDEX_W=max(1,ceil(log2(NUM_NODES)))`. Tags are uninterpreted bit fields.
There is no fixed-point arithmetic, runtime node allocation, node deletion or
component splitting. Public parameters are fixed at elaboration; illegal
settings fail through a deliberately unresolved parameter-error instance.
Derived localparams are internal.

| s_op / echoed m_op | Action | Successful response |
| --- | --- | --- |
| 0 FIND | Look up s_a; ignore s_b | m_root is a's representative, m_same=1, m_merged=0 |
| 1 UNION | Join components containing a and b | m_root is the resulting representative, m_same=1; m_merged=1 exactly when distinct components were joined |
| 2 SAME | Query connectivity of a and b | m_root is a's representative, m_same reports equal components, m_merged=0 |
| 3 CLEAR | Restore all singleton nodes; ignore both IDs | m_root=0, m_same=0, m_merged=0, m_groups=NUM_NODES |

`m_tag` echoes s_tag. `m_groups` is the **post-command** component count, with
`COUNT_W=max(1,ceil(log2(NUM_NODES+1)))`; it is meaningful with m_valid.
FIND checks only a; UNION/SAME check both IDs. An invalid required ID returns
m_error=1, zero root/same/merged, and preserves the partition and group count.
Valid commands have m_error=0. A self-union or already-connected union makes
no structural change and returns m_merged=0. Clearing an already singleton
partition still initializes every entry and emits one completion.

Output backpressure blocks further commands. Reset also cancels unconsumed
results; peers must restart canceled transactions. There is no separate busy
or completion pulse, timeout, bus error protocol or configuration-update race.
CE-qualified legacy streams require a semantics adapter before connection.

## Algorithm, storage and latency

Each node stores a parent and rank in one synchronous RAM entry. Lookup walks
parents to a self-parented root. Distinct roots are linked by rank: higher rank
wins; equal ranks select the lower root ID and increment its rank. Thus the
representative follows rank history and the deterministic tie rule. FIND and
SAME do not write memory. No path compression or speculative parallel queries
are performed. This keeps all memory accesses serialized through one read
port and one explicit write port, avoiding a multiport parent array.

Union-by-rank guarantees tree depth at most floor(log2(NUM_NODES)). Rank width
is sufficient for that bound, including NUM_NODES=1. Parent values remain legal
node IDs; linking different roots cannot create a cycle. The controller uses
READ then CAPTURE for every parent access. LINK writes the losing root;
equal-rank PROMOTE writes the winner on a separate clock. Initialization,
reads, link writes and promotion writes are mutually exclusive, so no RAM
collision mode is required. Reset controls ownership, then explicitly fills
RAM; no old entry is read before a complete initialization.

Default storage is `64*(6+3)=576` logical bits. The maximum is
`4096*(12+4)=65536` bits. Default qualitative resource risk is **LOW**; maximum
storage and its target RAM mapping have **MEDIUM** risk until mapped. State
storage grows linearly with node count, while lookup work grows with rank
depth. There is no multiplication/division, external memory, ROM initializer,
vendor primitive or vendor-specific attribute. Actual BRAM/LUTRAM mapping,
device fit, area, timing and power have not been measured.

Measured in clock periods from command acceptance to result-valid, let da and
db be the parent depths at command start:

- FIND: `2*(da+1)`.
- SAME or already-connected UNION: `2*(da+db+2)+1`.
- Distinct UNION: `2*(da+db+2)+2`, plus one clock for equal-rank promotion.
- CLEAR: NUM_NODES.
- Invalid ID: zero (response valid on the acceptance edge).

The earliest response transfer is the following edge; with an always-ready
sink, successive command starts are two periods farther apart than valid
latency. Sink stalls extend completion time without a finite unconditional
bound. Initialization after reset takes NUM_NODES active clock edges and emits
no unsolicited response. These are schedule properties, not measured Fmax or
hardware-throughput claims.

## Offline use and finite evidence

`files.f` lists the entire production closure. The default
`examples/disjoint_set_example.sv` exposes the command and result interfaces.
No includes, packages, coefficient tables, generated RTL or third-party
libraries are needed. Original source is Apache-2.0 under the repository
LICENSE; reference and semantic reuse decisions are recorded in SOURCES.md.

```text
python -B cores/acceleration/disjoint_set_union/sim/run.py
```

The Python standard-library runner prefers the local OSS CAD Suite, then PATH;
IVERILOG/VVP overrides are supported. Each subprocess has a 15-second limit.
Missing tools, timeouts or failures produce a non-pass verification.json.
Vectors and simulation binaries are regenerated in a task-specific temporary
directory and removed automatically. All delivered text has LF line endings.

Status: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**. The example is an
**INTEGRATION_CANDIDATE**. verification.json records source hashes and actual
commands. Seven cases cover node counts 1/2/3/8/17/64/256 and tag widths
1/4/8/32, totaling 3876 oracle commands. The independent model keeps explicit
Python component sets with representative/rank metadata, without parent
pointers or the RTL schedule. Balanced merges exercise increasing rank and
deep finds; tests also cover repeated/self unions, connectivity, singleton
clear/reuse, invalid IDs, ignored b on FIND, tag capture, input gaps and held
outputs. Each configuration has 14 elapsed-time reset-cancellation probes
during union/held output and clear initialization, followed by singleton reuse.
Those probes do not establish exhaustive FSM-state coverage. The maximum
4096-node profile is only compiled; four illegal configurations are rejected.
Unlisted sequences and parameter tuples are not proven. Synthesis, PnR, STA,
hardware and full regression were **NOT_RUN**.

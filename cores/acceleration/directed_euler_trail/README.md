# Directed edge-exact Euler trail

`directed_euler_trail` consumes a runtime directed multigraph and a requested
start, then returns a complete walk using every retained edge exactly once.
Self-loops and parallel edges remain distinct. Existing reachability, graph
cuts, spanning forests, minimum mean cycles and coloring do not provide this
edge-exact traversal. This is a bounded serial FPGA service, with no host path,
external memory, graph library, vendor primitive or generated lookup table.

## Transaction contract

One clock, synchronous active-high `rst`, no CE or CDC. Commands transfer on
`c_valid && c_ready`, rows on `s_valid && s_ready`, results on
`m_valid && m_ready`. `c_start`, `s_from`, `s_to` are unsigned32 and are checked
before narrowing. A command owns `c_tag` and begins a separate row frame.
The accepted `s_last` ends this frame. Masked rows ignore both endpoints;
a masked LAST alone describes an empty graph. No input timeout is imposed.

The first retained row has edge ordinal zero. Each subsequent retained row
gets the next ordinal, independently of intervening masked rows. Up to
MAX_EDGES retained rows are allowed. Capacity counts all retained rows,
including invalid endpoints, and saturates at the limit while the frame
continues draining. Endpoint errors remain sticky even after capacity fills.

| m_error bit | Meaning |
|---|---|
| 0 | Command start is >=NUM_NODES |
| 1 | A retained endpoint is >=NUM_NODES |
| 2 | More than MAX_EDGES retained rows |
| 3 | Valid input has no Euler trail from the requested start |

Input errors OR together, are reported only after LAST, and skip all solving.
Bit3 occurs only with bits2:0 zero. Any error produces one masked LAST token
with the command tag and zero node, incoming edge, step, edge count and
has-edge. No partial walk is published. Invalid commands still drain a frame.

A successful e-edge graph emits e+1 kept records. `m_step` runs 0..e,
`m_node` is the vertex, and `m_in_edge` at step j>0 identifies the retained
edge from the previous vertex to this vertex. `m_has_edge` is zero on the
first record, whose incoming-edge field is canonical zero. `m_edges=e` and
the tag repeat on every record. LAST occurs only at step e. The first vertex
is exactly the requested start. Empty graphs succeed with that single vertex;
isolated vertices elsewhere do not prevent a trail. There is no scaling,
rounding, signed arithmetic, implicit endpoint wrapping or edge deduplication.

Every vertex visit scans retained edges in ascending ordinal order. This
defines a deterministic witness via the documented stack/reversal procedure;
no shortest-path or lexicographically minimum-path objective is promised.
Hold the complete command/row while offered and blocked. All output fields
remain stable while valid and blocked. Ownership ends only when final output
is accepted. There is no next-command/final-output fallthrough. Ordinary
ready/valid requires an explicit adapter to existing CE-qualified streams.

Reset gates all ready/valid low and cancels capture, pending reads, traversal,
validation, prefetch or held output on the active edge. It clears control,
public data and the used bitmap, but never clears payload RAM. Per-command
counts bound every read, each stack frame is pushed before being popped,
and every route entry is appended before validation or replay. A subsequent
command therefore cannot consume a canceled graph's payload.

## Architecture and bounded work

| Parameter | Default | Legal |
|---|---:|---|
| NUM_NODES | 8 | 1..16 |
| MAX_EDGES | 32 | 1..64 |
| TAG_W | 8 | 1..32 |

Derived V=max(1,ceil(log2 N)), E=max(1,ceil(log2 M)), C=ceil(log2(M+1)),
R=ceil(log2(M+2)) are local constants. Invalid public parameters fail
elaboration through `directed_euler_trail_invalid_parameters__see_README`.

Serial Hierholzer uses three packed synchronous single-port RAM banks:
M endpoint pairs, M saved `(vertex,incoming ordinal)` stack frames and M+1
reverse-route records. A resettable M-bit used map provides edge identity.
Finding an unused outgoing edge marks it once, pushes the current record and
advances to its destination. Exhausted vertices append to the reverse route
and restore one saved record. Completion first requires all e edges consumed
and exactly e+1 cached records. A second pass validates the requested start
and every consecutive vertex against the original incoming-edge endpoints.
Only a completely certified route reaches output. Thus degree-invalid graphs
cannot expose a discontinuous Hierholzer splice. Degree/connectivity conditions
are the independent oracle rather than another hardware memory pass.

Each RAM read has a separate consume clock. There is no combinational array
read, reset loop, read/write collision dependency, multiplier, divider or
unbounded hardware loop. Runtime indexes have explicit vector widths.

Logical RAM is `M*2V+(2M+1)*(V+E)` bits: **712 default /1802 maximum**.
Clocked scalar/read/bitmap declarations total
`13+M+5C+R+9V+6E+TAG_W`: **146 /223 bits**, including all three RAM read
registers. These are declaration budgets, not mapped FF/LUT/BRAM results.
Qualitative architecture risk is LOW default /MEDIUM maximum: variable
selectors and small RAM mapping dominate. Device fit, RAM inference, timing,
power and sustainable board throughput have not been measured.

Let Q be actual edge scan reads and k consumed edges. Traversal plus global
check consumes `2Q+4k+3` clocks after accepted LAST. Success then uses
`4e+2` validation clocks and two output-prefetch clocks, yielding exact first
valid latency `2Q+8e+7`. There are e pushes and e+1 exhausted visits, so
Q<=e(2e+1) and success latency <=`4e^2+10e+7`: **4423 default /17031 maximum**.
Empty graphs take seven clocks. Input errors appear immediately after LAST
(latency zero). A no-trail response can stop at global or adjacency validation;
the secondary schedule certificate checks its exact actual path. After a
nonfinal output transfer, two prefetch clocks precede next valid, giving
unstalled record acceptance interval three. Row capture has II1. External
waiting can be unbounded and is excluded from internal latency.

## Frozen finite qualification

`TEST_PLAN.json` and six complete fixtures were frozen before RTL creation.
The matrix is six N/M/T profiles: 1/1/1, 2/3/3, 3/5/8, 5/12/8, 8/32/8,
16/64/32; version, core/example syntax, each profile's compile/main/reset,
and six expected parameter rejects total **27 child records**. Each compiler
or simulator has a hard 20-second timeout. A timeout is terminal: no retry,
smaller stimulus or extended deadline. Ordinary failures retain complete
original source, plan and receipts before any explicitly recorded repair.

The primary oracle uses degree imbalance and weak connectivity, independently
of the hardware traversal. Every input with <=5 edges also uses direct edge
permutation search. N2 and N3 exhaust all ordered multigraph edge lists of
length0..3 and every requested start, including parallel and self edges.
Finite directed splice, full-capacity walks/self-loops, wrong starts,
disconnected balanced graphs, vertex permutations, unsigned32 extremes,
masked rows and sticky combined errors cover the larger profiles.

Each observed walk is checked for the requested first vertex, every original
edge ordinal exactly once and every consecutive endpoint. A separate schedule
certificate checks exact first-valid latency and scan reads, not feasibility.
The source places real next commands/rows early and holds them to acceptance;
every output is stalled for two complete edges. All fields and all synchronous
RAM read values are checked.

Each profile has 21 predeclared immediate reset targets: all17 FSM states
(HOLD at the final record after prior retirement), partial capture, maximum
stack, held command error and overflow drain. The target is observed after a
falling edge; reset is asserted before the next active edge, with no extra
work edge. Every cancellation is followed by a complete M-edge fresh frame,
all M+1 outputs, and checks of every edge/stack/route entry. Total126 reset
groups and full-capacity fresh transactions are required.

Run once from repository root: `python -B cores/acceleration/directed_euler_trail/sim/run.py --run`.
`verification.json` records actual stdout/stderr, sources and plan hashes,
per-child statuses and finite totals. Missing or unexecuted work is never PASS.
Until that receipt exists, maturity is RTL_CANDIDATE /HW_UNVERIFIED. A successful
receipt adds UNIT_SIM_PASS only for the frozen finite matrix. No synthesis,
PnR, STA, board test, inherited matrix rerun or expanded regression is allowed.
The example is only a complete instantiation, not an integration test.

The first attempt stopped on an ordinary TB guard failure, not a timeout:
four children passed, N1 main simulation failed, and22 children were NOT_RUN.
The guard compared used_count against a new command's cleared edge_count
while LOAD still retained the previous graph's used_count. INIT establishes
that counter's new ownership before any traversal read. The repair confines
only that comparison to active solving/validation/prefetch; all permanent
capacity bounds remain checked. No RTL, fixture, oracle, reset target,
input handshake or deadline changed. The runner additionally retains partial
output text on any later ordinary failure. Complete original17 files,
including plan, original SOURCE_FREEZE and raw receipt, are in
`history/attempt_00.json`, SHA256
`4a591a29ca62f1f2bd5dc7481b76240bdeb5b31703161f61f4e58ef1df646166`.
Original receipt SHA256 is
`91bf98c3d2229083aa9b198b6690750e04885c634fa1147793301fa503d2d7a2`;
the frozen matrix SHA256 remains
`5a585ba7da97bba4761edd98a04d2d49e8e5abecbf06cf3ba58c5995b4dc6f01`.
`history/repair_01.diff` records the complete TB/runner/documentation delta;
the current source binding includes both exact archive and repair evidence.


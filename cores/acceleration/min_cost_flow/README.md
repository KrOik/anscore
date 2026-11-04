# Directed multigraph minimum-cost requested flow

Independent portable RTL candidate; **HW_UNVERIFIED**. `verification.json`
is authoritative for LINT_PASS / UNIT_SIM_PASS. No synthesis, implementation,
timing, power, board or inherited-regression evidence is claimed.

The core returns `F=min(command.limit, maximum source-to-sink flow)` and the
minimum nonnegative total original-edge cost among feasible flows of value F.
It publishes every kept original edge's flow, including zero-capacity and
zero-flow edges, in input ordinal order. Parallel, antiparallel and self edges
are distinct. Capacity shortfall is a normal result. No particular optimal
flow vector or lexicographic tie result is part of the interface contract.

Existing `maxflow_mincut` has no price objective and uses a simple capacity
matrix. `min_cost_assignment` covers unit-capacity square matching only.
`signed_sssp` computes distances without a capacity-constrained flow. Their
actual contracts were read before selecting this independent capability.

## Transaction and stream contract

Single clock; synchronous active-high `rst` cancels the current transaction,
including any held output. No CE, CDC or asynchronous peer protocol is present.
Ordinary ready/valid transfers occur on a rising edge with both high.
The producer holds valid and the complete payload until acceptance.

1. A separate command accepts full **unsigned 32-bit** source, sink and requested
   flow limit, plus TAG_W tag. It owns the core until the final output retires.
   Source and sink are validated before narrowing. Equality is checked
   independently, including equal out-of-range terminals. An invalid command
   still consumes its entire following edge frame.
2. Edge tokens carry full unsigned32 from/to, unsigned CAP_W capacity and COST_W
   price, keep, last and upstream error. Each kept token consumes one of
   MAX_EDGES ordinals, including invalid endpoints and zero capacities. Count
   saturates at MAX_EDGES; any additional kept token sets overflow. Endpoints
   and upstream errors remain validated after overflow. Masked payload fields
   are ignored; last and upstream error remain effective. Last closes the frame
   even on a masked token. An empty frame needs a masked last token.
3. Input errors accumulate independently: bit0 terminal range; bit1 equal
   terminals; bit2 edge endpoint range; bit3 kept overflow; bit4 upstream error.
   Any error produces exactly one masked last result with zero index, edge
   flow, total flow and total cost, false target_met and the command tag.
   Bit5 indicates an internal invariant failure and is not a legal-input
   outcome; any appearance fails numerical/protocol checking.
4. A valid nonempty frame publishes one kept record for each original edge,
   ordinal0..E-1. Repeated total_flow, total_cost, target_met, error0 and tag
   accompany every record; last is true only for the final record. Empty frames
   publish one masked last summary with index/edge_flow zero. For limit0 the
   minimum-cost zero flow is returned, and every nonempty edge row still appears.

Only c_ready in IDLE or s_ready in LOAD can be high. There is no command/input
fallthrough or output/input fallthrough. Input stalls are unbounded while
solving or publishing. Held output and all metadata remain stable through
backpressure; no next command is accepted before final retirement. Configuration
and tag change only on command acceptance. Payload RAM is not reset: the complete
edge frame is owned before solving; every scratch node is initialized before
read and each path slot is written before replay.

## Numeric widths and serial architecture

| Parameter | Legal / default |
|---|---|
| NUM_NODES |2..16 /8|
| MAX_EDGES |1..32 /16|
| CAP_W, COST_W |1..8 /8; original costs nonnegative|
| TAG_W |1..32 /8|

V=max(1,clog2(N)), EI=max(1,clog2(M)), FW=CAP_W+clog2(M) and
TW=CAP_W+COST_W+clog2(M). These derived public width parameters must retain
their default expressions. No input terminal or endpoint truncation can admit
an out-of-range value. FW covers sum of all capacities and TW covers sum of
capacity times price over all original edges. Even the maximum 32*255*255
cost fits TW=21. The command limit stays unsigned32 throughout comparison.

Successive shortest residual paths use strict-improvement, in-place
Bellman-Ford for at most N-1 complete passes. Each ordinal is scanned forward
then reverse. Residual capacities are cap-flow and flow; reverse price is
signed negative original price. No heap, parallel vertex comparator array or
N-by-N capacity matrix is present. Parents trace sink to source, computing the
bottleneck and storing at most N-1 path entries, then replay to update edges.
The entire result is solved before a separate final cost sum and publication.

Initially every residual cycle has nonnegative cost. Augmenting a shortest
residual path preserves that property, so the achieved flow is globally
minimum-cost for its value. After bounded relaxation, tight final parent edges
cannot contain a cycle: a strict parent improvement requires an earlier final
parent value, and a cycle of those dependencies would contradict temporal
order. Trace length is therefore at most N-1. The guarded internal bit5 paths
also prevent an accidental unbounded trace or zero augmentation.

Distance DW=COST_W+clog2((N-1)*2M+2)+1, default17 / maximum19. This covers the
transient signed chain through all relaxation events, not merely the final
simple shortest-path cost. The magnitude is bounded by
(N-1)*2M*(2^COST_W-1); one sign bit and the conservative extra endpoint cover
all initialized/temporary arithmetic. Final costs use unsigned products.

Three packed banks have a single scheduled synchronous access per cycle:

| Bank | Bits |
|---|---|
| Original from,to,capacity,cost,flow |M*(2V+2CAP_W+COST_W)|
| Reach,distance,parent ordinal,direction |N*(DW+EI+2)|
| Saved path ordinal,direction |(N-1)*(EI+1)|

Total logical payload RAM is **699 default /1530 maximum bits**. Actual clocked
scalar declarations, including all bank output registers and output ports,
total **297 /349 bits**. Count expression is
EB+NB+PB+6+8V+3EI+EC+2NC+4+4CAP_W+3DW+FW+TW+(CAP_W+COST_W)+32+TAG_W+9,
where EC=clog2(M+1), NC=clog2(N+1). Payload RAM is never bulk-cleared.
Scheduled read/use/write states avoid bank collisions. These small packed
banks may map to LUTRAM/FF instead of a physical BRAM; inference is not measured.
One shared CAP_W-by-COST_W multiply, at most8-by8, feeds a full product register
and later accumulator. DSP or LUT mapping is a tool choice; zero DSP is not
claimed. Storage risk LOW, serial control/arithmetic risk MEDIUM, worst-case
service latency risk HIGH. No external memory, vendor primitive or sibling RTL.

For A successful augmentations and F returned flow, A<=F<=M*(2^CAP_W-1).
A conservative no-input-bubble, no-output-stall bound from accepted last input
to first valid output is:

`2+(A+1)*(N+4+(N-1)*(20M+4))+A*(16*(N-1)+8)+4+3M` clocks.

INIT costs N; each pass scans at most2M arcs, each within10 clocks; at most
N-1 passes plus pass bookkeeping fit the term shown. Trace and replay fit
16*(N-1)+8 per augmentation. The final read/product/add costs3E and output
setup fits the final constant. Replacing A by F remains conservative, as used
in frozen per-frame bounds. Invalid input latency is exactly1 clock. Outputs
after the first require read/use setup and retirement; arbitrary backpressure
precludes an unconditional wall-clock deadline or throughput promise.

## Frozen finite evidence

The complete `TEST_PLAN.json` and213 JSON fixtures were generated before the
first RTL file: SHA256
`92d8672234ebe28b2b334c5bc5d424cd49929728086536a214d6c03ae5707ad9`.
They freeze six profiles 2/1/1/1/1,3/3/2/2/3,4/6/3/4/8,5/12/4/4/8,
8/16/8/8/8 and16/32/8/8/32 (N/M/CAP/COST/TAG),1775 main frames,
7566 input tokens,6178 expected main records,317 immediate reset/full-capacity
fresh sequences and232 children including10 illegal-parameter rejections.
Fixture grouping and reset exclusions are immutable. `prepare_matrix.py`
refuses regeneration. `SOURCE_FREEZE.json` binds all final sources and exact
command templates before any HDL child.

The independent primary oracle builds any feasible requested flow by unweighted
BFS and then cancels globally negative simple cycles. It does not implement
the DUT's shortest-cost augmentation or RAM phases. Every retired DUT edge
flow is independently certified for capacity, conservation, exact objective,
exhaustive source-side minimum cut and Floyd-Warshall global residual
no-negative-cycle optimality. Direct enumeration of all flow allocations
crosschecks1520 main cases; reference optimization performs66 cycle cancellations.
Reference flow vectors are retained as evidence but never require DUT vector
equality. All32 input-error combinations, unsigned32 range boundaries,
parallel/reordered/antiparallel/self edges, reverse cancellation, zero target,
empty graph, unreachable sink, exhaustive small graphs and seeded multigraphs
have fixed inputs and exact integer expectations.

The37 state targets and17 semantic reset targets have explicit per-profile
reachability exclusions in the plan. The first observed falling-edge target
asserts reset before the next rising edge. Every subsequent fresh completes
all M edge outputs using every edge row, every scratch node and N-1 path slots.
Main groups hold the next frozen command until it is actually accepted after
final retirement; single-frame jobs have no internal cross-frame acceptance.
Canceled owners offer only their already frozen fresh command. No extra end
prefix is added. Payload ownership is checked on every scheduled RAM read;
all records and metadata are held for two clocks and checked for stability.

Run from this package using local Icarus, with its bin and lib on PATH:
`python -B run_tests.py --freeze-source`, then exactly once
`python -B run_tests.py --run`. Every child has a hard20-second timeout;
TIMEOUT is terminal. Any ordinary failure preserves all original sources,
plan, seal, receipt, NOT_RUN and produced artifacts before a separate root
decision. There is no automatic retry. `--audit` reads evidence only.

`files.f` is the complete production dependency closure. The example adds
one default-width ready/valid instance. Offline production use requires only
these two local SV files; Python, fixtures and upstream libraries are not
production dependencies. Interface adapters are required for CE-qualified
streams or different command framing.

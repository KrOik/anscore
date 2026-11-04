# Exact signed shortest distances and negative-infinite vertices

`signed_sssp` accepts raw directed signed-weight edge updates and one source.
It returns every vertex's exact finite shortest distance, reachability, and
whether its distance is unbounded below because a reachable negative cycle can
reach it. Negative cycles in unreachable components do not invalidate finite
results. This complements the existing nonnegative Dijkstra/tree service and
unweighted reachability/SCC service; neither supplies these signed semantics.

## Graph, arithmetic and error contract

The universe is every vertex0..NUM_NODES-1, including isolated vertices.
WEIGHT_W-bit weights and DIST_W-bit distances are signed two's-complement exact
integers. A kept token assigns {present,weight} to ordered (from,to): **last
assignment wins**, including deletion. Reverse edges are independent. Valid
self-loops are ordinary edges, including negative loops. There is no parallel
edge multiplicity, edge-token capacity, scaling, rounding or numeric saturation.

The first accepted token owns `s_source` and `s_tag`, even if masked. Later
source/tag fields are ignored. A masked token ignores endpoints, presence and
weight but still owns framing. `s_first` must be1 exactly on the first accepted
token and0 thereafter. `s_last` closes the graph and may be masked. A masked
first/last token represents an edgeless graph. A missing last waits until input
or reset without an implicit timeout or restart.

Full unsigned32 source/from/to IDs are validated before narrowing. Sticky error
bit0 is an invalid first source, bit1 any kept invalid endpoint (including
deletion), bit2 FIRST disagreement. These are independent; all8 combinations
are meaningful. Any error drains through last and atomically rejects the graph:
one masked first/last record has the first tag and errors, with **all vertex,
source, distance and reach/cycle fields zero**. No prefix analysis is published.

A valid graph returns N kept records in ascending `m_vertex`, first at0 and
last atN-1, repeating source, first tag and global `m_has_negative_cycle`:

| Fields | Meaning |
|---|---|
| reachable=0, negative_infinite=0 | No directed source-to-vertex path; distance0 |
| reachable=1, negative_infinite=0 | Exact finite signed shortest distance |
| reachable=1, negative_infinite=1 | A source-reachable negative cycle can reach this vertex; distance0 is canonical |
| has_negative_cycle | At least one source-reachable negative cycle exists |

There is no unreachable negative-infinite state. The source may itself be
negative-infinite if a negative cycle can return to it. Other finite vertices
remain valid even when the global cycle flag is1. Zero distance can be finite,
unreachable or canonical negative-infinite; use flags to distinguish them.
No parent tree, path witness, all-pairs distances or cycle reconstruction is
returned. Such structures require additional semantics with negative cycles.

## Clock and transaction ownership

One rising-edge clock, synchronous active-high `rst`, ordinary valid&&ready;
no CE, CDC or runtime configuration. All source fields stay stable while valid
and blocked. Reset gates ready/valid low immediately and its active edge cancels
input, relaxation, propagation or held/partially delivered output. Public output
registers clear. After reset N*N clocks clear adjacency serially before ready;
each valid graph then initializes both distance banks before any distance read.
There are no array-wide memory resets or stale reads after cancellation.

One graph owns capture, computation and all output records. Every output field
and valid is stable under sink backpressure; reset overrides the hold. No next
graph transfers on the final output edge, and a fresh adjacency clear follows.
The caller discards any canceled partial output graph and replays input if
needed. Legacy CE-qualified neighbors require an explicit adapter.

Parameters: NUM_NODES=8 (1..32), WEIGHT_W=8 (1..16), TAG_W=8 (1..32).
NODE_W=max(1,ceil(log2 N)), COUNT_W=ceil(log2(N+1)),
DIST_W=W+ceil(log2 N)+1. Derived parameters are local. Illegal public settings
fail elaboration through `signed_sssp_invalid_parameters__see_README`.

## Architecture and structural budget

Distance bank k holds minimum cost of walks with **at most k edges**, plus a
separate reach bit. Each new target begins with its previous value and serially
checks every incoming edge against the immutable old bank. Separate synchronous
read and consume states keep all additions within one path-length increment.
After a changed pass the bank roles swap. An unchanged pass is a fixed point,
so finite solving can stop early. Otherwise pass N compares D_N with D_(N-1)
and seeds vertices whose value improves. The old bank D_(N-1) remains selected
for finite outputs. An Nth improvement implies a reachable negative cycle;
every downstream vertex is negative-infinite. Monotone edge scans propagate
seed flags for at most N-1 passes, stopping on no changes or skipping when all
vertices are already seeded. Unreachable negative cycles produce no seed.

D_k uses walks of at most k<=N edges, so every arithmetic candidate is bounded
by N*2^(W-1) in absolute value, including signed minimum weights. DIST_W includes
a guard bit; the candidate adder keeps another bit before exact narrowing.
Negative-cycle iteration cannot accumulate unbounded wrapped values because
relaxation stops at N, then propagation uses only presence/flags. Variable
address stride multiplication is by elaborated constant N. No runtime weight
multiply/divide, vendor primitive, external RAM, ROM/init file or host result
is required.

One synchronous adjacency RAM uses N*N*(W+1) bits and two synchronous distance
banks use2*N*(DIST_W+1) bits: **784 default /18880 maximum raw bits**. Memories
are read/written in disjoint states, with no read-during-write assumption.
The negative flags are N scalar bits. All explicitly declared scalar storage,
including read data/control/public outputs, is
`W+4*DIST_W+7*NODE_W+AW+2*COUNT_W+N+2*TAG_W+24`
bits (AW=max(1,clog2 N*N)): **139 default /281 maximum bits**. These are RTL
declaration budgets, not mapped resources. Risk LOW default/MEDIUM maximum is
qualitative; RAM packing and serial service time need physical review.

If K relaxation passes and P propagation passes occur, always-ready final-input
to final-output-transfer latency is exactly
`4*N + K*(N*(2*N+3)+1) + P*(2*N*N+1)` cycles. First valid is3N-2 cycles earlier.
K<=N, P<=N-1 give conservative final bounds2159 default /132287 maximum. Invalid
graphs first assert valid after1 cycle, earliest retirement after2. Capture can
accept one update/cycle; output records need read/load/transfer (II3). Initial
or inter-graph clear and input/output stalls extend overall service. Unbounded
external stalls imply no unconditional completion deadline. No frequency,
board throughput, area, power or timing result is claimed.

## Offline example and finite checks

`files.f` is the entire production closure. `example/signed_routes8.sv` directly
exposes the default ordinary ready/valid instance; it has syntax/instantiation
evidence only. Root LICENSE/NOTICE apply. SOURCES.md records actual upstream
body/full-license inspection, semantic differences and independent authorship.

Run `python -B cores/acceleration/signed_sssp/sim/run.py`. TEST_PLAN.json freezes
the six finite profiles before any HDL check. Every compiler/simulator child
has a hard20-second limit; a timeout is terminal with no retry, fixture shrink
or limit increase. Ordinary qualification failures retain original receipts and
source hashes before the identical frozen matrix can be repaired.

The independent oracle computes all-pairs Floyd-Warshall distances and tests
reachability through each negative diagonal pivot. For N<=5 it independently
enumerates all simple paths and simple cycles, then crosschecks finite distances
and negative-cycle downstream classifications. It does not implement DUT bank
swaps, incoming-edge order or seed propagation. Tests cover signed extrema,
self-loops, reachable/unreachable cycles, partially affected graphs, deletion,
last-assignment replacement, ignored fields, all8 errors, all256 two-node graphs
over absent/-1/0/+1, full N32 numerical fixtures, source gaps, output holds and
blocked next input. Pass counts, exact first-valid timing and signed candidate
range are checked. Immediate reset probes assert on the observed low boundary
before another active edge and each complete fresh recovery verifies all nodes.
N1 propagation states9/10/11 are unreachable and explicitly skipped.

`verification.json` is the authoritative current hash-bound finite maturity.
UNIT_SIM_PASS is limited to the frozen matrix. Synthesis, PnR, STA, board tests
and expanded regression are NOT_RUN; all physical status is HW_UNVERIFIED.

The original six-profile matrix passed all21 bounded tool records, including
six named parameter rejections, without failure or timeout. Main traffic was
451 graphs,3565 input tokens and1832 output records; every profile covered all8
error patterns. The451 exact first-valid checks observed maxima9/43/127/541/
2137/132193, including one graph/profile that forces K=N and P=N-1. The131
immediate reset probes each completed a fresh edgeless graph and checked every
vertex. These separate recovery transactions are excluded from main counters.

The independent small enumeration crosschecked353 valid graphs and enumerated
235 negative simple cycles (including unreachable ones). Main outputs had607
finite,553 unreachable and624 negative-infinite vertices;154 finite distances
were negative and95 positive. There were183 graphs with reachable negative
cycles and65 unaffected finite vertices in those graphs. Main activity was
579678 relaxation candidates,36562 propagation edges,1351775 cycles,3322 held
output cycles and1343057 blocked-input cycles. Current/tested source maps
preserve the README-only results refresh after the qualified run; no numerical
rerun or implementation/test/plan change followed qualification.

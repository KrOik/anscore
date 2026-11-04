# Rooted directed minimum arborescence

Independent portable RTL candidate, **HW_UNVERIFIED**. `verification.json` is
the authority for LINT_PASS / UNIT_SIM_PASS of the exact source closure.
No synthesis, place-and-route, STA, power or board result is claimed.

Given a fixed-size directed multigraph and a runtime root, return an exact
minimum-cost spanning out-arborescence: every nonroot has one incoming edge,
all parent chains terminate at the root, and the sum of original unsigned
edge costs is minimum. Parallel and self edges retain distinct input ordinals.
Self edges consume input capacity but cannot enter a tree. Infeasibility is
a normal result. Any optimal witness is legal; globally lexicographic tie
selection is not promised.

This differs from `kruskal_msf` (undirected forest, endpoint normalization),
`directed_reachability` (closure/SCC with no weighted-tree objective), and
`min_cost_flow` (capacitated requested flow). Their actual interfaces and
implementation boundaries were read before choosing this capability.

## Interface

One clock, synchronous active-high `rst`, ordinary ready/valid, no CE or CDC.
Transfers occur on rising edges when valid and ready are high. A producer
holds all fields until acceptance. Reset level immediately gates ready/valid
and end markers; an active reset edge cancels capture, solve and output.
Previously retired witness prefixes must be discarded by the receiver on reset.

Each accepted input token carries unsigned32 `s_root`, `s_from`, `s_to`,
unsigned COST_W `s_cost`, TAG_W `s_tag`, `s_keep`, `s_last`, and `s_error`.
The first accepted token snapshots root and tag; later root/tag changes are
ignored. Every kept token consumes an ordinal, including loops and invalid
endpoints. The kept count saturates at MAX_EDGES. Masked geometry is ignored;
LAST and upstream error still apply. An empty graph uses a masked LAST token.
The core drains through LAST even after an error. Full32 root/endpoints are
validated before narrowing, including independent checks after overflow.

Sticky independent error bits: bit0 root outside `[0,N)`, bit1 kept endpoint
outside `[0,N)`, bit2 more than MAX_EDGES kept tokens, bit3 accepted s_error.
An error yields only one summary: feasible0, all geometry/cost/total zero,
the combined error mask, original tag, summary1 and LAST1. A valid graph with
no rooted tree yields the same zero result with errors0. For N1, the empty
tree is feasible with cost0.

A feasible graph emits N-1 edge records in ascending child order, skipping
the root, followed by a separate summary. Each edge has summary0/LAST0,
unsigned32 child, parent and original kept ordinal, and its original cost.
The final summary has summary1/LAST1 and zero geometry/edge cost. Every
record repeats the final total, feasible1, errors0 and snapshot tag. There
is no prefix before complete capture/validation/optimization. Outputs and
all metadata stay stable under backpressure. No next input can transfer
before the final summary retires; the earliest transfer is the next edge.
An unterminated input or unconsumed output can wait indefinitely.

## Parameters and architecture

|Parameter|Legal range|Default|
|---|---|---|
|NUM_NODES|1..12|8|
|MAX_EDGES|1..32|16|
|COST_W|1..12|8|
|TAG_W|1..32|8|

The serial Chu-Liu/Edmonds controller chooses minimum incoming edges (local
equal-cost ties choose the first ordinal), identifies predecessor cycles,
assigns components, and transforms all edge slots into the next layer.
Every real contraction strictly reduces the node count. The root cannot
be in a predecessor cycle. Missing incoming edges terminate as infeasible.
At the final acyclic layer, selected incoming edges form a tree. Expansion
first restores every previous minimum edge, then replaces the entry at the
previous-layer destination of each selected current-layer original ordinal.
That replacement breaks each contracted cycle at its actual entry vertex.

Two unreset, packed, synchronous memories retain layer history. Each performs
at most one read OR write per edge. Every node row is initialized for its
layer; every edge row is loaded/transformed before it is read. Disabled edge
slots are explicitly written. Expansion reads only completed earlier layers.
There are no data multipliers/dividers or vendor primitives. Address products
are by constant parameter strides. One COST_W subtraction and one total-width
addition are serially scheduled with the memory accesses.

Let V=max(1,clog2 N), E=max(1,clog2 M). Edge memory has `N*M*(1+2V+C)` bits;
node history has `N*N*(6+C+3V+2E)` bits. The two memories total **3,904 bit**
at default parameters and **13,824 bit** at the maximum. Actual declared
sequential scalar storage, including both RAM read registers, is **123/178
bit** at default/maximum. Combinational addresses, write-data muxes and
control wires are excluded from that scalar FF budget. Default architecture
risk LOW, maximum MEDIUM; small packed banks may infer LUTRAM or fragmented
BRAM. These are logical counts and qualitative risks, without physical results.

Adjusted crossing-edge costs remain in `[0,2^C-1]`: subtracting the target's
minimum incoming cost cannot underflow and never increases a cost. Internal
or self edges are disabled with zero data. Total width is
`COST_W+ceil(log2(max(1,N-1)))`, enough for `(N-1)*(2^C-1)` without truncation.
The final sum uses selected layer0 original costs.

With complete input, no output stall and valid parameters, a conservative
tail bound is `4N^3+24N^2+16NM+32N+64` cycles (5,952 default; 16,960 maximum).
It bounds full serial work and result preparation; input gaps and output
backpressure add waiting cycles. The finite TB checks first-valid against
this bound, and complete output with a separate bounded watchdog. This is
an architectural cycle bound, not a timing/frequency or throughput measurement.

## Offline use and finite qualification

Compile from this directory using `iverilog -g2012 -s
directed_minimum_arborescence -f files.f`; the example manifest elaborates
`arborescence8`. Production closure is the single listed RTL file. No network,
generated ROM or external memory is required.

`TEST_PLAN.json` and all 572 fixture files were frozen before RTL. Five
profiles cover N1/M1/C1/T1 through N12/M32/C12/T32, 884 main frames, 250
independent reset owners and 250 full-capacity fresh frames. Reset owners
cover all reachable planned states plus cycle entry/exit, nested layers,
reweighted costs, reverse expansion, partial output prefixes and held actual
next offers; small-domain exclusions are explicit. Complete fresh output is
checked after every reset. Output prefixes are checked as valid original-edge
witness records; one particular optimal tie vector is never required.

The oracle enumerates original incoming-edge choices, rejects parent cycles,
and minimizes exact integer cost. At most 118,098 combinations can exist with
12 nodes/32 edges. This does not reuse contraction or the RTL FSM. The TB and
runner independently check the returned original-edge witness, rooted parent
chains, exact optimum, ordering, metadata, stalls, RAM ownership/ports and
the finite latency bound. Pre-RTL arithmetic cross-checking additionally
matched the exhaustive oracle against a separate cost-only contraction model,
including five nested contraction levels in this finite set.

`python -B run_tests.py --freeze-source` binds all final package files before
the first HDL child. `--run` executes exactly 301 frozen children: 2 lint,
5 compiles, 286 simulations and 8 named parameter rejects. Each child has a
hard 20-second limit. TIMEOUT is terminal, leaving later children NOT_RUN;
ordinary failure preserves the exact tested source/plan/seal/receipt and
stops for review. No retry, splitting or smaller replacement stimulus is
automatic. `--audit` reads evidence and hashes without executing HDL.

Original code is Apache-2.0; see LICENSE. Reference-only CC0 source reading,
fixed revision, file hashes and complete license preflight are in SOURCES.md.

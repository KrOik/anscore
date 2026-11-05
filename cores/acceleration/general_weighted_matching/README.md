# Exact maximum-weight matching in a general undirected graph

`general_weighted_matching` selects vertex-disjoint edges with maximum exact
total signed integer weight. Odd cycles and non-bipartite graphs are legal.
Leaving any vertex unmatched is legal. This is a weight objective, without a
secondary maximum-cardinality requirement; zero and negative edges are never
selected. The edgeless/all-nonpositive result has total and cardinality zero.

This adds general-graph weighted pairing to the existing unweighted bipartite
matcher and square minimum-cost perfect assignment. The bounded subset-DP
architecture deliberately trades exponential memory/work for simple exact
integer control at N<=12. It is not a scalable blossom implementation.

## Transaction and interface

One clock, synchronous active-high `rst`, ordinary valid/ready, no CE or CDC.
Ready and valid are gated low while reset is asserted. Hold every offered input
field until an accepted rising edge. No other transfers occur during reset.

After reset and each final output retirement, N*N clocks serially clear the
edge bank before capture opens. Each accepted token has unsigned **32-bit**
`s_from/s_to`, signed two's-complement `s_weight`, and `s_present/s_keep/s_last`.
On a kept valid token the unordered pair is assigned the given weight/presence;
last assignment wins, including reversed endpoint order. `present=0` removes
the pair. Masked tokens ignore endpoints, weight and presence. The first
accepted token captures the tag, even when masked. Later tags are ignored.
A masked last token describes an empty graph. There is no fixed edge count or
implicit tail; a missing accepted last waits until reset.

Both full-width endpoints must be in 0..N-1 before address narrowing. A kept
self-loop is also invalid, even on deletion. Any invalid kept token rejects
the complete graph, while input continues draining through the accepted tail.
Endpoint error (1) has frame-wide priority over self-loop error (2). No partial
matching is published. Invalid addresses never access RAM.

Success emits exactly N kept rows, `m_node=0..N-1`, last on row N-1. Each row
reports whether that vertex is matched, its partner (zero when unmatched), the
completed graph's common edge cardinality, exact nonnegative total weight and
first tag. Matched rows occur in symmetric pairs; cardinality counts edges,
not matched rows. An error emits one masked last row with the nonzero error
code, first tag and all numerical fields zero. All output fields remain stable
under backpressure. Capture is blocked through computation and output.

Equal optima use this deterministic rule at every remaining-vertex subset:
try leaving its lowest vertex unmatched first, then pair it with increasing
partner IDs, replacing the prior choice only for a strictly larger total.
Input order has no effect after resolving last-wins assignments. This rule
does not promise lexicographically minimal partners or maximum cardinality.

Reset cancels capture, DP work, traceback and held rows. Edge RAM is serially
cleared before reuse. DP[0] is written for the new owner, and every nonzero
subset is committed in increasing numeric order before being used. Payload
RAM and synchronous read-q are not reset. Results already retired belong to
the canceled transaction; the receiver must discard that incomplete frame.

## Exact representation and architecture

|Parameter|Default|Legal|
|---|---:|---|
|NUM_NODES|8|1..12|
|WEIGHT_W|16|1..32 signed integer bits|
|TAG_W|8|1..32|

Port widths are localparams: IW=max(1,clog2 N), CW=clog2(N+1), and
SCORE_W=max(1,W-1+clog2(max(1,floor(N/2)))). At W=1 the only weights are -1
and 0, so every graph has the empty optimum. No fixed-point scale, rounding,
saturation, floating point or finite infinity sentinel is used.

For nonempty S, let v be its lowest vertex. The exact recurrence is

`D[S] = max(D[S\{v}], w(v,j)+D[S\{v,j}] for present positive edges to j in S)`.

Every matching either leaves v unmatched or uses exactly one such edge, so
the recurrence is exhaustive. Removing a vertex gives a smaller numeric mask;
therefore increasing-mask writes ensure all child entries are current. Each
entry stores its nonnegative score and a partner+1 choice (zero=unmatched).
Traceback removes one or two vertices per step and builds a small symmetric
partner vector before any output becomes visible.

A matching has at most P=floor(N/2) edges. For P>=1 and W>=2, its positive
total is at most P*(2^(W-1)-1), strictly below 2^(W-1+clog2(max(1,P))). The
SCORE_W width therefore covers every committed score. A SCORE_W+1 candidate
adder precedes comparison; only a proven in-range winning result is narrowed.
The input sign bit is tested before a weight is considered. Zero/negative
weights cannot improve a solution because unmatched vertices are permitted.

The banks are synchronous-read, single-read-or-write per cycle with disjoint
access states. No read/write collision, asynchronous memory read, DSP, variable
multiplier/divider, external memory, vendor primitive or downloaded runtime is
required. Constant address products and bounded priority/index selectors remain
ordinary RTL logic. Existing assignment/flow solvers have different graph and
objective contracts and cannot act as this backend without implementing the
general-graph problem again; no old core is modified.

## Cost and finite service bound

Logical RAM is `N*N*(W+1) + 2^N*(SCORE_W+CW)` bits: **6464 default**, **160400
at N12/W32**. The first bank stores only canonical upper-triangle accesses in a
simple square address space; the second is the DP bank. Declared scalar and
read-q storage, including partner/matched vectors, totals
`8+2W+3*SCORE_W+4*CW+AW+3N+2*IW+N*IW+TAG_W` bits, where
AW=max(1,clog2(N*N)): **175 default**, **322 at all maxima**. These counts are
source declarations, excluding mapped RAM overhead, routing and tool transforms.

A conservative accepted-tail to first-valid observation bound is
`(4N+5)*(2^N-1)+2N+4` clocks. Each subset takes a base read, at most N-1 serial
edge/child probes and a commit; traceback has at most N steps. Errors complete
sooner. Success rows then retire one per clock with continuous ready. After the
last retirement another N*N clear sweep precedes new capture. Input gaps and
output backpressure are unbounded, so no unconditional wall-clock latency,
clock frequency or sustained overlapping-graph throughput is promised.

Default architectural risk **LOW**, maximum **MEDIUM**, primarily from the
exponential DP capacity/work and wide add/compare/index path. No synthesis,
placement/routing, STA, power or board result exists for this implementation.

## Offline delivery and current evidence

`files.f` lists production RTL; `example/files.f` and `general_match8.sv` expose
the complete default interface. Standard-library reference, fixed tests and a
strict finite runner are being authored. No preparation, oracle, compiler or
simulator has run for this package. Current status is **RTL_CANDIDATE +
HW_UNVERIFIED**. Qualification can change only after the reviewed fixed plan
and exact sources are sealed and explicitly approved; no inherited matrix or
combined snapshot checker is part of this package's plan.

Original Apache-2.0 contribution; see LICENSE, NOTICE and SOURCES.md.

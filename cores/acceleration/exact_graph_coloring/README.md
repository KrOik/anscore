# Exact minimum colouring of a raw conflict graph

`exact_graph_coloring` accepts an undirected graph, computes its exact chromatic
number and returns a complete optimum vertex-to-colour assignment. It can map
small pairwise-conflicting operations to the fewest time slots. Existing
maximum_clique selects a compatible subset and cannot provide this assignment:
a five-cycle has clique number two but requires three colours. This service is
exact over its declared domain; it has no greedy approximation mode.

## Interface and ownership

| Parameter | Default | Legal domain |
|---|---:|---|
| NUM_NODES=N | 8 | every integer 1..10 |
| TAG_W | 8 | 1..32 |

Each nonempty input frame defines a fresh simple graph with all fixed vertices
`[0,N)`, including isolated vertices. A kept, in-range, distinct-endpoint beat
assigns edge `{s_u,s_v}` according to `s_present`. Both endpoint orders,
overwrites and deletions are supported; last assignment wins. In-range
self-loops are explicitly ignored, as in the existing simple-graph clique
contract. This input convention does not model mathematical looped graphs.
Masked endpoints/presence are ignored. Kept endpoints are checked as full
unsigned32 values before narrowing, including out-of-range self-loops.

FIRST must be1 on the first accepted beat and0 on every later beat. The first
accepted beat owns the tag, even when masked. Accepted LAST ends collection;
without LAST the frame remains open. Error bit0 reports a kept out-of-range
endpoint, bit1 any FIRST violation. Errors accumulate, inhibit further graph
updates, drain to LAST, and return one canonical `m_colors=0,m_count=0` response
with the first tag and sticky error. No errored adjacency is published.

On success `m_count[CW-1:0]`, `CW=clog2(N+1)`, is the global minimum number of
colours. Vertex u has unsigned colour `m_colors[u*CW+:CW]`, in `[0,m_count)`.
Adjacent vertices differ, every returned colour is used, and all N vertices
are assigned. An edgeless graph returns count1/all-zero colours. The complete
assignment, error, count and tag share one result token, with no output LAST.
Colour names follow a deterministic backtrace: at each remaining subset,
choose its first optimum independent colour class in descending numeric-mask
order containing the subset's least vertex, assign the next colour starting
at0, and remove that class. A wholly independent subset is one class directly.
This is a precise tie policy, not lexicographically smallest vertex colours.

One rising-edge clock, synchronous active-high reset, ordinary ready/valid,
no CE, CDC, runtime configuration bank or external memory transaction. Transfers
occur on valid&&ready. A producer holds valid/all fields through stalls until
acceptance or reset. Collection accepts masked/self-loop tokens at II1; each
real edge needs four intervening symmetric read/write clocks. Search and a
held result block input. Every result field remains stable under backpressure.
After retirement, N serial clear clocks precede another frame's admission.
Caller input gaps and output stalls have no finite bound.

Reset immediately gates ready/valid low. Its active edge cancels collection,
half-updated edges, DP, backtrace or held success/error. N serial row clears
follow reset release; no old ownership survives. Holding reset restarts clear
without resetting the RAM arrays. Table/read-data banks are unreset: entry0 is
written, every subset reads only smaller entries, and all entries are rebuilt
before backtrace. The known non-independent current subset is excluded from
candidate reads. Read/write phases are disjoint; no collision mode is assumed.

## Algorithm, budgets and latency

For ascending numeric subset S, remove its least vertex v to form P. The exact
independent flag is `ind[S]=ind[P] && !(adj[v]&P)`, with ind[0]=1. If independent,
DP[S]=1. Otherwise enumerate every nonempty proper submask I in descending
order; for independent I containing the least vertex of S, minimize
`1+DP[S\I]`. Every proper colouring has exactly one class containing that
vertex, and its complement is smaller than S. Induction proves the global
optimum. Strict improvement preserves the first optimum class. DP[0]=0.
Backtrace follows stored classes and terminates after exactly DP[all] classes.

The alternative brute-force assignment search has irregular branches; a fully
parallel subset implementation would need many replicated ports. This design
uses one N-row adjacency RAM and one `2^N`-row packed table (independent flag,
CW-bit count, N-bit chosen class), each with one synchronous read/write port.
There is one bounded lowest-bit priority encoder, N-bit mask logic and one
CW-bit min add/compare; no multiplier/divider, DSP primitive, recursion,
generated ROM or sibling core. The logical RAM budget is
`N*N + 2^N*(N+CW+1)`: **3392 bits default /15460 maximum**. Clocked scalar/read/response declarations are
`6N+N*CW+4CW+3IW+TAG_W+12`, IW=max(1,clog2 N):
**125 default /172 maximum**. Combinational temporaries and elaboration loop indices
are excluded. These are declared bit counts, not measured LUT/FF/BRAM usage.
Small banks may map to registers. Qualitative architecture risk is MEDIUM;
exponential capacity/work limits N to10. No physical fit, Fmax, power or board
throughput is claimed.

Let C be the number of nonempty proper submasks scanned across non-independent
S; F the number that are independent and contain S's least vertex; K the
optimum. From accepted LAST to first result-valid, exact success latency is
`2+4*(2^N-1)+2C+2F+2K+4E`, where E=1 for a kept valid distinct-endpoint tail,
otherwise0. An error takes exactly1 clock. Since C<=3^N-2^N and F<=C, the
conservative success bound is `4*3^N+2N-2+4E`, at most **26262 default /
236218 maximum clocks**. Result transfer needs another edge. Serial clearing,
frame capture and caller stalls add to complete service time. N10 has actual
numerical simulation in the frozen matrix; it is not a compile-only promise.

## Offline use and finite qualification

`files.f` names the sole production source; `example/conflict_slots8.sv` forwards
the full default protocol. Compile from this package directory:

```text
iverilog -g2012 -Wall -tnull -s exact_graph_coloring -f files.f
iverilog -g2012 -Wall -tnull -s conflict_slots8 -f files.f example/conflict_slots8.sv
python -B sim/run.py --freeze
python -B sim/run.py
```

The delivered TEST_PLAN.json is already frozen; the freeze option refuses
overwrite. The runner also refuses to overwrite verification.json. SOURCES.md
records the actual full upstream/complete-license reads and semantic dedup
before RTL. All code is original repository Apache-2.0 work. Offline production
needs no untracked files, external packages, generated images or network.

The finite plan fixes six N/T profiles 1/1,2/3,4/5,6/8,8/8,10/32, every input
and oracle hash, and25 child records: version, two syntax checks, six TB builds,
twelve simulations (main and reset separately) and four expected parameter
rejections. Each child is limited to20 seconds. Timeout is terminal and retains
TIMEOUT/NOT_RUN; no smaller vectors, raised limits or retries are allowed.
Ordinary failures require exact preserved receipts and a same-matrix repair.
No successful qualification is automatically repeated. No synthesis, PnR, STA,
board test or expanded regression is performed.

Main fixtures include all simple graphs at N1/N2/N4, empty/complete/path/star,
bipartite/crown, odd-cycle and odd-wheel clique gaps, disjoint cliques, seeded
graphs and renumberings, overwrite/delete/reversed edges, masked first-tag
ownership, self-loops, full-width endpoint errors and all sticky error values.
The primary oracle directly assigns vertex colours under each increasing
colour limit. Through N4, a separate edge-subset inclusion/exclusion chromatic
count proves no colouring at K-1 and a positive count at K. A secondary subset
certificate checks the deterministic witness, every actual adjacency/table
word, complete operation counts and exact first-valid latency. Every vertex
and original edge in each returned assignment is checked independently.

Main traffic preoffers real subsequent tokens and verifies stable holding
through actual acceptance; output stalls check all fields. Twenty-two reset
groups per profile cancel every reachable FSM state, partial collection,
mid-clear and held error immediately upon observation before another active
edge. N1's unreachable real-edge and non-independent-search phases explicitly
alias START. Each cancellation is followed by a complete fresh edgeless graph,
tag/count/colour checks, all adjacency and all DP words, held output and actual
retirement. This is finite unit evidence, not exhaustive schedule/parameter
proof. The actual maturity, command receipts, measured coverage/counts, current
hashes and any prior failures are recorded in **verification.json**; physical
status remains **HW_UNVERIFIED**.

The original frozen six-profile qualification passed all25 child records on
its first attempt, including four expected elaboration rejections. There were
no failed attempts, timeouts, warnings or retries; maximum child time was
14.219 seconds. Main traffic completed216 graphs/1963 tokens, with180 valid
and36 erroneous frames (12 each error1/2/3). The independent assignment oracle
visited1771 partial assignments;122 small-graph inclusion/exclusion crosschecks
passed, including all67 simple graphs across N1/N2/N4. Every one of216 exact
first-valid checks passed; maxima by profile were8/28/196/1678/15148/135680
clocks. The actual DP images contained22822 checked words and839 checked
adjacency rows. All839 output vertices and886 original edges passed proper
colour checks. There were22642 subset preparations,843478 candidate scans,
94941 complementary DP reads and425 backtrace classes. All1976274 main blocked
source cycles passed explicit holding checks;1585 held tokens subsequently
completed actual handshakes.858 blocked output cycles passed stability checks.
All132 immediate reset groups completed their full fresh transaction and
complete RAM-image checks. Current maturity is
**LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED**.

The measured-results paragraph and wording corrections in README/SOURCES
are the only post-PASS source changes. The exact tested README, SOURCES, frozen
plan and original PASS receipt are embedded verbatim with SHA256 values in
`history/qualification_001_docs.json`. Current documentation/plan/hash metadata
is rebound without re-executing the original25 tools or either oracle.

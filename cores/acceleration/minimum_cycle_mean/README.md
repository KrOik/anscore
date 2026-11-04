# Exact minimum mean of a directed weighted cycle

`minimum_cycle_mean` accepts raw signed directed edge updates and returns the
minimum over all positive-length cycles of sum(edge weights)/number of edges.
Disconnected components and self-loops participate. It distinguishes an acyclic
graph from a cyclic graph of mean zero. No source, initial potentials, SCC
labels or host-computed path information is required.

## Numeric and graph contract

Parameters NUM_NODES=8 (1..32), WEIGHT_W=8 (1..16), TAG_W=8 (1..32).
The static vertex set is0..N-1, including isolated vertices. A kept token assigns
{s_present,s_weight} to the ordered pair(s_from,s_to); last assignment wins,
including deletion. Reverse edges are independent. There is no parallel-edge
multiplicity or edge-token limit. All weights are exact signed two's-complement
integers. A kept self-loop is an ordinary cycle of length1.

Unsigned32 endpoints are checked before narrowing, including deleted edges.
Masked tokens ignore endpoints, presence and weight. The first accepted token
owns the tag, even if masked. FIRST must be1 exactly on that token and0 later.
LAST closes the graph, including a masked tail. A masked FIRST/LAST represents
an empty graph. A missing LAST waits for more input or reset without a timeout.
Sticky error bit0 denotes any kept endpoint>=N; bit1 denotes FIRST disagreement.
Any error drains through LAST and atomically rejects the entire graph.

Exactly one ready/valid response belongs to each completed graph. On success
error=0. If a cycle exists, has_cycle=1 and signed numerator/positive denominator
encode its exact minimum mean. The fraction is **not necessarily reduced**, and
is a Karp difference quotient, not a promised cycle-weight/cycle-length pair.
The denominator is1..N. No pivot or cycle path is claimed. For an acyclic graph,
has_cycle=0 and numerator=denominator=0. Error responses also canonicalize all
three fields to zero, retaining only the first tag and error bits. A cyclic
zero mean must be distinguished using has_cycle. There is no rounding,
saturation, division, square root, floating point or approximate result.

IW=max(1,clog2 N), CW=clog2(N+1), DW=W+ceil(log2 N)+1, NW=DW+1,
PW=NW+CW. The signed numerator port has NW bits; denominator has CW bits.
Illegal public parameters fail elaboration through the named unresolved
minimum_cycle_mean_invalid_parameters__see_README module.

## Ownership and reset

One rising-edge clock, synchronous active-high reset, ordinary valid&&ready;
no CE, CDC or runtime configuration. Hold all source fields until acceptance
or reset. Reset gates ready/valid low immediately, cancels capture/computation/
held output on its active edge, clears public output registers, then clears
N*N adjacency words serially before accepting input. DP/read registers have no
array reset: every consumed row belongs to the current graph and was initialized
or computed before its read. No stale graph survives cancellation.

Capture can accept one update per cycle. One graph owns capture, computation
and its held response. Every output field stays stable during valid&&!ready.
There is no final-output/next-input fallthrough. Retirement starts another N*N
serial adjacency clear. Legacy CE-qualified streams need an explicit adapter.
External source gaps and sink stalls may be unbounded, so computation cycle
bounds do not imply an unconditional system deadline.

## Algorithm, width proof and structure

D_0(v)=0 for every vertex, representing an implicit zero-cost super-source.
For k=1..N, D_k(v) is the minimum cost of an **exactly k edge** walk ending atv,
with a separate reach bit. A serialized incoming-edge scan reads immutable
row k-1; an explicit store phase writes each completed row-k cell. It is not
an in-place shortest-path relaxation. Karp's characterization is

    minimum_v with finite D_N(v) maximum_0<=k<N,finite D_k(v)
        (D_N(v)-D_k(v))/(N-k).

This includes arbitrary disconnected graphs: adding one super-source and
applying the N+1-vertex characterization removes the first zero-cost edge and
gives exactly this formula. D_N is finite somewhere iff a positive-length
cycle exists, by the pigeonhole principle. D_0 is always finite, so each
participating vertex has a nonempty ratio set. Increasing vertex/k scans and
strict updates make the encoding deterministic; no global witness tie rule
is implied.

Every k<=N walk has absolute cost<=N*2^(W-1), including signed-minimum edges.
DW includes a guard bit. Candidate addition uses DW+1 bits before exact
narrowing. D_N-D_k has absolute value<2N*2^(W-1), fitting NW=DW+1.
All denominators are positive and<=N. Cross-products use PW=NW+CW signed bits;
one signed shift/add engine is reused for the two products of each rational
comparison, each in CW clocks. There is no runtime data multiply/divide/modulo
operator. Multiplication by elaborated N is only a constant address stride.

One synchronous adjacency RAM stores N*N*(W+1) bits; one synchronous DP RAM
stores N*(N+1)*(DW+1) bits. Default total1512bits, maximum41696bits. Reads and
writes occur in disjoint states; there is no read-during-write assumption or
parallel array reset. All explicitly declared scalar state, including public
outputs and unreset read registers, is
W+3DW+4NW+3PW+8CW+4IW+AW+2TAG_W+18, with AW=max(1,clog2 N*N):
231bits default/421bits maximum. Combined RAM/scalar totals1743/42117bits.
These are declaration budgets, not LUT/FF/BRAM measurements. Default structural risk LOW, maximum
MEDIUM for RAM footprint, wide comparisons and serialized cubic work.

For a valid graph, exact accepted-tail to first-valid latency is

    N + N*N*(2*N+2) + 3*N + 1
      + sum_over_reachable_D_N_vertices(
          3*N + F_v + 2*CW*(F_v-1) + 1 + 2*CW*G_v).

F_v counts reachable D_k(v) for0<=k<N; G_v is0 for the first participating
vertex and1 thereafter. The conservative bound is
2*N^3+6*N^2+5*N+2*CW*(N^2-1)+1, default1953/maximum84117 clocks, attained when
all exact-length cells are reachable. Invalid graphs assert first valid one
clock after their accepted tail. Initial clearing, input gaps and held output
extend full service time. No frequency, physical throughput or power is claimed.

## Offline use and finite evidence

Core dependency closure is files.f; example/cycle_mean8.sv is a complete raw
stream wrapper. Both only need local RTL. SOURCES.md records semantic dedup,
fixed upstream source/full license reads and independent implementation scope.
The independent primary oracle isolates a rational optimum using exact scaled
negative-cycle tests. A zero-reduced-cost cycle attains the answer, and a
potential vector makes every transformed edge nonnegative, proving the lower
bound. Small graphs additionally enumerate elementary cycles. A separate
exact-length table is only a secondary work/image certificate; it never
replaces the independent optimum. TB checks every consumed adjacency/DP word,
every DP store and both complete signed cross-products, with no numeric
tolerance. Reset probes cancel each reachable controller phase immediately and
then finish an analytic directed ring, checking all adjacency/DP cells, exact
latency, held output, retirement and absence of stale response. Source offers
are actual following frozen tokens held to acceptance, or reset-canceled probes.

TEST_PLAN.json freezes six profiles (N/W/T=1/1/1,2/3/3,3/4/5,7/8/8,8/8/8,
32/16/32) before any HDL tool, including all81 two-node graphs with each edge
absent/minimum/maximum, signed extremes, fractions, DAGs, disconnected cycles,
transients, deterministic dense/sparse graphs, updates/deletion, masking,
all error combinations and28 immediate reset/full fresh pairs per profile.
Each profile has compilation and one numerical simulation; two syntax checks
and six named parameter rejections complete the20-child matrix. All compiler/
simulator children have a fixed20second limit. A timeout is terminal, without
retries, fixture reduction or a raised limit. Ordinary failures retain their
exact source/plan/receipt and unchanged matrix if repaired. The runner's
--prepare mode only generates the frozen plan and independent fixtures;
normal invocation validates all hashes before the first HDL child.

Run `python -B sim/run.py` from the package. Actual status and counters belong
to verification.json; without a completed receipt this is RTL_CANDIDATE. Any
UNIT_SIM_PASS is restricted to its frozen finite matrix. All versions are
HW_UNVERIFIED: no synthesis, PnR, STA, board validation, resource measurement
or expanded regression. There are no inherited hardware claims.

The actual frozen run completed20 original child records, including six named
parameter rejections, on its first attempt, without failures, timeouts or
warnings. The largest child took19.000seconds within the fixed20second limit;
this finite evidence does not promise runtime on another machine. The352 main
graphs/6010 accepted tokens include310 valid graphs and42 errors:49 DAGs,
183 negative,57 positive and21 zero minimum means;41 fractional optima.
There are290 small-graph elementary-cycle crosschecks and261 exact
cycle/potential optimality certificates in the
full matrix. Exact fixture coverage is authoritative in TEST_PLAN.json.
All352 first-valid latencies match the independently derived schedule;
profile maxima14/63/156/1304/1953/84117 attain the declared full-reach bounds.
Main evidence includes26259 DP stores,710214 DP reads,694315 adjacency reads,
27878 full signed cross-products and145098 multiplier steps. Source holding
checks1615173 equal the blocked main cycles, with293 held output cycles.
All168 immediately canceled probes completed a full fresh ring, every RAM
cell and exact latency check. All18 states were observed for N>1; N1 excludes
the mathematically unreachable multiplier state. These are finite observations.

After successful numeric qualification, the summary parser was found to select
Icarus's appended finish-location line, leaving observed/totals metadata empty.
The original20 PASS records and independent numeric validations were complete.
history/qualification_001_receipt_parser.json preserves exact original runner,
README, plan and receipt text/hash; all remaining executed source bytes are unchanged.
Original executed plan SHA256
`c15c6f3bef3b0b11e54c0dba91f7cb15f38fb089e73d29dfb888a0ad70cabd7b`;
original receipt SHA256
`1d27eae8b79dbe2721633505a8cdb0549761e684ce9e2ffc40cc1ee7fd4b2c3f`.
Only PASS-line parsing/history awareness, this README and current metadata
hashes were corrected. Statistics were reconstructed from the original raw
stdout, with original records byte-for-byte equal. Current/tested source maps
and both plan hashes distinguish those versions; fixture bytes, parameters,
matrix, RTL, TB,20second limits and numeric validation are unchanged. No HDL
child or oracle was rerun. Embedded receipt records are copies of the same20
executions and do not add20 runs. Read verification.json for the current
canonical hashes and exact correction chain.

# Exact maximum clique from raw undirected edge updates

`maximum_clique` returns the exact maximum cardinality of a set of mutually
adjacent vertices and one complete witness bitmap. It solves pairwise
compatibility selection on a general undirected graph, including graphs with
odd cycles. Existing bipartite matching, directed flow/cut and additive budget
selection cores have different feasibility constraints. This core does not
return all maximal cliques, vertex colours, edge weights or a clique cover.

## Frame and result contract

| Parameter | Default | Legal domain |
|---|---:|---|
| NUM_NODES=N | 8 | every integer 1..16 |
| TAG_W | 8 | 1..32 |

Every frame describes a fresh graph whose fixed vertex set is `[0,N)`, including
isolated vertices. Thus a graph with no edges has optimum1, even if all input
beats are masked. At least one beat is required. Each accepted beat contains
unsigned32 `s_u/s_v`, `s_present`, `s_keep`, `s_first`, `s_last` and tag. A kept
valid distinct-endpoint beat sets or clears the undirected edge `{u,v}` using
`s_present`. Repeated updates, reversed endpoints and deletion are permitted;
the last accepted assignment wins. In-range self-loops are ignored. A kept
out-of-range self-loop is still an endpoint error. There is no multiplicity.
Masked coordinates and presence are ignored, but FIRST/LAST and tag ownership
still apply. Endpoints are validated at full unsigned32 width before narrowing.

The first accepted token owns the tag, including a masked first token. FIRST
must be1 exactly on that token and0 thereafter. Accepted LAST terminates the
frame; a missing accepted LAST leaves collection open without a result. Error
bit0 is a kept bad endpoint, bit1 is any FIRST violation; both are sticky and
all four combinations are reachable. An erroneous frame drains to LAST and
returns one canonical `m_vertices=0,m_size=0` response with its error and first
tag. Its private adjacency has no public meaning and is erased before reuse.

Every correct frame returns one `m_vertices[N-1:0]` bitmap and unsigned
`m_size[CW-1:0]`, `CW=clog2(N+1)`. Set bits form a clique, and their count equals
the global optimum. All valid vertices are present even if they never occur in
the edge stream. Traversal is deterministic, takes the lowest remaining vertex
first and retains the first witness of each strictly improved cardinality.
No separate global tie criterion is promised among multiple optimum cliques.
There is no output sequence/LAST; one response owns the complete result.

One rising-edge clock, synchronous active-high reset, ordinary ready/valid,
no CE, CDC, runtime configuration bank, external memory port or bus interface.
Input transfer is `s_valid && s_ready`; the producer holds valid and all fields
until that handshake or reset. Collection accepts masked/self-loop tokens at
II1; a real edge update requires four intervening clocks. One frame owns
collection, search and the held result. Every output field stays stable while
valid and blocked. Input remains blocked during search and held output. After
response retirement, N serial clear clocks precede another frame's admission.
Caller input gaps and output backpressure can be unbounded.

Reset immediately gates public ready/valid low. Its active edge cancels partial
capture, half-completed symmetric update, stack search or held normal/error
response. On release, one adjacency row is cleared per clock for N clocks,
with no input admission; previous ownership never survives this initialization.
Holding reset restarts the cursor without parallel RAM writes. Reset produces
no response. Stack/read-data banks are unreset: every restore has a preceding
same-search push and read, and every row use follows a current synchronous read.

## Bounded search and structural budget

Candidates contain only larger-index vertices adjacent to every selected
vertex. A depth-first extension adds the lowest candidate, saves the parent's
remaining candidates/clique in synchronous stack RAM, reads that vertex's
adjacency row and intersects it with the remaining set. If the candidate set
is empty or `depth+popcount(candidates)<=best_size`, no extension can improve
the best cardinality; the parent is synchronously restored. Every clique is
generated at most once because selected indices strictly increase. Root
exhaustion proves the optimum. There is no recursion in hardware.

One N-bit adjacency RAM with N rows supports a single synchronous read and
write. Each distinct-endpoint edge uses read-A/write-A/read-B/write-B, with no
read/write collision or two writes in one clock. One synchronous 2N-bit stack
RAM has N rows. Push and pop phases are separate. Neither memory has a reset
tree, complete-array combinational read or external dependency. Lowest-bit
priority and population count are bounded combinational logic on at most16
bits; the upper-bound add/compare and selection mux are expected control paths.
There is no multiplier, divider, DSP primitive or generated adjacency image.

With `IW=max(1,clog2 N)`, RAM declarations total `3N*N` bits: **192 default**,
**768 maximum**. Scalar/read/response declarations total
`6N+3IW+2CW+TAG_W+9`: **82 default**, **159 maximum**. Counts include unreset read
registers, omit combinational wires, and describe logical declarations rather
than measured LUT/FF/BRAM mapping. Small banks may map to registers. Resource
risk is qualitatively LOW default/MEDIUM maximum; Fmax, memory inference,
power, physical fit and board throughput are unmeasured.

Let R be the number of chosen extension branches. Each push has one pop before
root exhaustion. From the accepted tail to first result-valid, exact latency
is `2+6R+4E`, where E=1 only for an error-free distinct-endpoint kept tail that
requires a symmetric update. An error takes exactly1 clock. Since
`R<=2^N-1`, correct-frame latency is at most `6*2^N` clocks: **1536 default**,
**393216 maximum**. The service deliberately caps N at16 and remains
exponential in the worst case. Output transfer needs another edge; the next
transaction also needs the N-row clear and its own collection. These bounds
do not include caller gaps/stalls and are not measured hardware rates.

## Offline use and finite qualification

`files.f` contains the sole production source. Compile from this package root:

```text
iverilog -g2012 -Wall -tnull -s maximum_clique -f files.f
iverilog -g2012 -Wall -tnull -s clique8 -f files.f example/clique8.sv
python -B sim/run.py
```

The optional `clique8` wrapper forwards the default interface. It establishes
syntax/instantiation evidence only. Root LICENSE/NOTICE cover original local
Apache work. SOURCES.md records actual semantic dedup and fixed upstream code
and full-license reads before RTL. Production use needs no untracked files,
includes, sibling modules, ROM tables or network. Local attributes pin LF from
package creation.

TEST_PLAN.json is frozen before the first HDL tool. It fixes six N/T profiles
1/1,2/3,4/5,6/8,8/8,16/32, every input SHA/count, the full finite command matrix,
four illegal parameter rejections and16 reset/fresh targets per profile. The
maximum profile has finite numerical fixtures; no size is silently compile-only.
The plan includes empty/complete graphs, paths, stars, complete bipartite and
tripartite cases, planted/disjoint cliques, seeded and renumbered graphs,
reversed overwrite/delete streams, self-loops, masked first tag ownership and
all framing/endpoint errors. All simple graphs through N4 are enumerated.

The independent Python oracle enumerates vertex subsets and directly checks
every chosen pair. For N<=6 a separate minimum vertex-cover enumeration on the
complement graph crosschecks the optimum. TB output checks include every public
field, exact first-valid latency, complete symmetric adjacency image for valid
frames, actual source holding through acceptance, held results and exact token/
response counts. Search traces independently verify clique membership, depth,
candidate ordering and compatibility, and the incumbent witness at every
SEARCH observation. These invariants supplement the independent final optimum.

Reset is asserted immediately after observing each target, without another
active edge. Probes cover serial clear first/middle, idle/partial collection,
all four half-edge update phases, search entry, row read, descend, both parent
restore phases, and held normal/error results with blocked source. At N1 the
four distinct-endpoint update phases cannot occur and explicitly alias START.
Every cancellation is followed by a complete fresh star graph, exact optimum,
symmetric metadata checks and a held/accepted response. Main traffic preoffers
real subsequent frozen tokens and keeps them through acceptance; held-source
reset probes are explicitly canceled by reset.

Every compiler/simulator child is limited to20 seconds. Timeout is terminal;
the receipt retains TIMEOUT/NOT_RUN without retry, smaller vectors or increased
limits. Ordinary concrete failures may be repaired only with an explicit
reason and the identical frozen matrix, preserving original receipts/hashes.
Successful matrices are not automatically rerun. Current statuses, source and
fixture hashes, original commands, observed counts and any history belong in
verification.json. This is finite unit evidence, not exhaustive schedule or
parameter proof. No synthesis, PnR, STA, hardware or expanded regression runs.

The original six-profile matrix passed all19 bounded child records on its
first attempt, including four expected elaboration rejections, without timeout
or diagnostic warnings. Main traffic completed349 frames/5914 beats, with295
valid and54 erroneous graphs; error0/1/2/3 counts are295/18/12/24. Coverage
includes67 exhaustive small graphs,175 cases with multiple optima,200 proper
cliques and219 complement-cover crosschecks. All six complete-graph fixtures
reached their full legal search depth. All2565 pushes had matching pops;
5425 search invariants and22982 candidate-membership checks passed, along with
349 exact first-valid checks and788 selected witness vertices. Main held
cycles were321, and all37520 blocked-source cycles also passed explicit stable
holding checks. Every one of96 immediate reset probes completed its full
fresh-star transaction. Maximum observed first-valid latencies by profile were
8/18/36/54/108/900, with maximum extension counts1/2/5/8/17/149. These are
finite observations; the conservative exponential bound remains unchanged.

Current maturity is **LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED**. No historical
failures, timeouts or reruns occurred. Only this measured-results documentation
refresh follows the qualified pass; verification.json retains tested/current
hashes and the prior receipt hash. RTL, TB, runner, plan, vectors, files.f and
example remain exactly those qualified.

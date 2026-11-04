# Directed all-pairs reachability and strong components

`directed_reachability` accepts directed edge assignments and computes every
vertex's reflexive reachable set, strongly connected component (SCC), forward
and backward reach counts, membership in a positive-length cycle, and the
global DAG predicate. It supplies a reusable routing/dependency analysis
service without requiring host-computed labels, traversal order or closure.
Weighted single-source Dijkstra, undirected cut structure and disjoint-set
connectivity have different graph semantics and do not supply this result.

## Transactions and numerical meaning

The static universe contains every vertex 0..NUM_NODES-1, including isolated
vertices. Ordinary rising-edge `s_valid && s_ready` accepts a token. A kept
token assigns s_present to the **ordered** pair (s_from,s_to): last assignment
wins, including deletion. Reverse endpoints describe a different edge. There
are no parallel edges. Both endpoint ports are unsigned32 and checked before
narrowing, including deletion and self-loop offers. A kept endpoint >=N marks
the whole graph invalid. Masked tokens ignore both endpoints and presence.

The accepted s_last closes the graph, including a masked tail; a masked tail
alone represents an empty edge set. The first accepted token owns the tag,
even when masked. Later tags are ignored. There is no update-count limit or
input timeout; an unterminated graph waits for more input or reset.

A valid graph produces N kept records in ascending m_node order, last only
at N-1, with error=0 and the first tag. All values are unsigned exact integers
or bitmaps; no fixed point, scaling, rounding or saturation is involved.

| Output | Meaning |
|---|---|
| m_reachable[j] | A path from m_node to j, including the zero-length self path |
| m_scc_members[j] | j and m_node are mutually reachable |
| m_scc_root | Minimum vertex in this SCC; **not** a dense component ID |
| m_scc_size | Population of m_scc_members, 1..N |
| m_components | Number of SCCs in the whole graph, repeated on every record |
| m_forward_count | Population of m_reachable, including self, 1..N |
| m_backward_count | Vertices which can reach m_node, including self, 1..N |
| m_cyclic | Positive-length cycle contains this vertex |
| m_acyclic | Whole graph is a DAG, repeated on every record |

Reachability always contains the diagonal. Explicit self-loop presence is
tracked separately: deleting a self-loop preserves zero-length reachability
but can remove the positive-cycle flag on a singleton SCC. A vertex is cyclic
iff its SCC has size>1 or its final explicit self-loop is present. A one-way
edge between SCCs does not merge them. At N1, no edges gives singleton masks,
counts1, cyclic0, acyclic1; an explicit self-loop changes only cycle/DAG flags.

Any kept bad endpoint atomically rejects the complete graph. It returns one
masked last record with error=1, first tag and **all numerical fields, masks
and both cycle flags zero**. There is no partial graph result.

Hold all source fields stable while valid and blocked. Every output field
and valid stays stable during `m_valid && !m_ready`. The graph remains owned
until its final record transfers. There is no next-input/final-output
fallthrough; initialization precedes capture of the next independent graph.

## Clock, storage and architecture

One rising-edge clock, synchronous active-high rst; no CE, CDC, runtime
configuration, external RAM, vendor primitive or generated table. Reset
also gates ready/valid low while asserted. An active reset edge cancels
capture, pending RMW, closure/SCC work or held normal/error output and clears
public outputs. The next N-clock initialization writes reflexive singleton
rows and clears explicit-loop bits before input becomes ready. Summary RAM
is overwritten for every vertex before replay. No canceled memory content
is used in a later graph. Replay canceled work if needed. Existing
CE-qualified stream interfaces need an explicit adapter.

| Parameter | Default | Legal |
|---|---:|---|
| NUM_NODES | 16 | 1..64 |
| TAG_W | 8 | 1..32 |

IW=max(1,clog2 N) for vertex IDs, CW=clog2(N+1) for all counts. Derived local
parameters are not user configuration. Invalid public parameters fail
elaboration through `directed_reachability_invalid_parameters__see_README`.

Closure is an N-row, N-bit synchronous memory. A legal non-self edge uses
CAPTURE, IN_READ, IN_WRITE: the read-modify-write has input II3. Masked,
invalid and self-loop tokens can transfer at II1 while capture remains open.
A variable bit update selects one of the N bits. Separate self-loop storage
prevents explicit edge removal from deleting the reflexive diagonal.

The solver caches pivot row k, then reads and updates every row i. If row i
contains k, it ORs the cached pivot into that row. This serial Warshall
schedule computes reflexive transitive closure without an N-by-N array of
parallel combinational operators. The pivot row cannot change during its
own reflexive phase, so caching is valid. Each memory read has a distinct
following consume state; read/write collision behavior is not assumed.

For each vertex i, the SCC pass saves its forward row then scans closure rows
j synchronously. Mutual bits identify SCC membership; ascending scan chooses
the minimum representative. The same scan counts forward/backward reach.
A separate summary memory stores each mask/root/count tuple. A representative
equal to i increments the global SCC total, and any cyclic vertex sets the
global cycle flag. Replay starts only after all summaries and global flags
are settled. Closure and summary reads are captured on the next clock before
the held output state. All storage is local and included by files.f.

Closure plus summary RAM uses `N*N + N*(N+IW+3*CW)` logical bits: **816** at
default and **9920** at maximum. The declared scalar/read/output registers,
including the explicit-loop bitmap, total `16+8*N+12*IW+11*CW+2*TAG_W` bits:
**263** / **741**. These are logical declaration counts, not mapped resource
measurements. The combinational input-update temporary is not counted as
stored bits. There are no variable multipliers, dividers or scratch register
arrays. Qualitative risk is **LOW** default / **MEDIUM** maximum: row-wide
ORs, variable selectors and narrow small-memory mapping dominate. LUT/FF/
BRAM utilization, timing, device fit and power remain unmeasured.

After accepted tail, the conservative first-valid observation bound is
`4*N*N+6*N+8` clocks, including a pending input RMW, pivot/SCC scans, initial
replay read and sampling margin. Error output is earlier. With continuous
ready, subsequent records transfer every3 clocks. After final retirement,
N initialization clocks precede ready; earliest next acceptance is N+1
periods after retirement. Source gaps or output stalls prevent a whole-graph
deadline. These schedule statements are not hardware frequency claims.

## Finite evidence and offline use

`python -B sim/run.py` needs only standard-library Python and installed
Icarus/vvp. Every tool child is limited to20 seconds. On timeout that check
stops and records TIMEOUT_NOT_RUN; the runner does not reduce fixtures or
retry. It overwrites old evidence with NOT_RUN before starting and publishes
PASS only after every planned check and source hash succeeds.

The six fixed profiles are N1/2/3/7/16/64, with tags1..32. They include all
16 N2 and all512 N3 directed matrices (self-loops included), empty/complete/
chain/star/cycle/disconnected SCC graphs, one-way SCC links, explicit-loop
set/clear, repeated/deleted edges, masked illegal32-bit endpoints, atomic
errors and same-final-graph replay under reordered assignments. Independent
Python BFS checks every reach bit, iterative Kosaraju checks SCCs, and Kahn
deletion checks the DAG predicate. Mutual reach crosschecks SCC membership.
No oracle uses the RTL Warshall recurrence. Every result field is compared.

Reset probes immediately cancel all17 FSM states (non-self input states2/3
are unreachable and omitted at N1), held normal/error outputs after four
blocked clocks, an interior closure update and an interior SCC reverse scan.
Each cancellation is followed by a fully checked fresh empty graph:124
immediate cancellations/recoveries overall. Every main output is deliberately
held at least four clocks; source and complete output stability are asserted.
Conservative first-valid bounds are checked. Stall counters include probes
and recovery; main frame counts exclude them. Four illegal parameter settings
must fail with the named guard. These are finite tests, not a full proof.

`examples/directed_routes16.sv` exposes all ports with fixed defaults and adds
no dependencies. It is an **INTEGRATION_CANDIDATE** with syntax evidence.
Core maturity is **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED** as recorded in
verification.json, bound to exact RTL/example/TB/runner hashes. No synthesis,
PnR, STA, board test or expanded regression ran. Root Apache-2.0 LICENSE and
NOTICE cover this original implementation. Actual fixed upstream source and
full-license preflight, with no copied dependency, is recorded in SOURCES.md.

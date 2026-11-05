# Exact DAG transitive reduction with an unchanged closure backend

`dag_transitive_reduction` returns the unique minimal-edge subgraph of a DAG
with exactly the same reachability. It adds edge elimination and an essential
edge certificate contract beyond the existing closure/SCC service. The actual
production module `../directed_reachability/rtl/directed_reachability.sv` is
instantiated unchanged; its existing numerical matrix is not rerun.

Maturity is currently **RTL_CANDIDATE + HW_UNVERIFIED**. No compiler,
simulation, preparation or synthesis evidence is implied by source existence.
Only a current matching `SOURCE_SEAL.json` and `verification.json` with
`UNIT_SIM_PASS` may qualify the explicitly finite matrix. No synthesis, PnR,
STA, board, frequency, power or mapped-resource measurements are requested.

## Transaction contract

NUM_NODES defaults16, legal1..64; TAG_W defaults8, legal1..32. All N vertices
exist, including isolated ones. One rising-edge clock and synchronous
active-high rst; ordinary ready/valid, no CE or CDC. Reset gates both public
ready and valid low, cancels all ownership, and sequentially initializes N
adjacency rows before input is accepted. RAM payload and read-q are unreset.

Each accepted token with s_keep1 assigns s_present to the ordered pair
(s_from,s_to); last assignment wins, including deletion. Self-loops are real
edges. Unsigned32 endpoints are validated before narrowing, even on deletion.
Masked tokens ignore endpoints/presence but still own first tag and tail.
The accepted s_last ends a graph; a masked tail alone is an empty graph.
There is no update-count limit, implicit restart or missing-tail timeout.

A valid DAG emits exactly N kept rows in ascending m_node, last only on N-1.
`m_successors[v]` marks an essential original edge from m_node to v.
`m_out_degree` counts that row; `m_edge_count` is the total reduced-edge count,
and `m_removed_count` is original final edge count minus reduced count.
The global counts repeat on every row. Values are exact unsigned integers
and bitmaps, with no scaling or saturation. First accepted tag is repeated;
later tags are ignored. All response fields hold under backpressure.

`m_errors=01` means at least one kept invalid endpoint. That rejection takes
priority and does not classify cycles. `m_errors=10` means all endpoints were
valid but the final graph has a positive-length directed cycle, including a
self-loop. Either error returns one keep0/last1 row, first tag, and every
numerical field zero. There is no partial normal graph output on an error.
Adding then deleting a cycle before tail is legal. At N1 the empty graph
returns one kept zero-successor row; an explicit retained loop is an error.

Every kept valid update uses a synchronous adjacency RMW, giving input II3.
Masked/bad tokens use II1 while capture stays open. Backend and wrapper accept
each external token on the same edge. All backend rows are drained before
classification/reduction or error output, so a canceled/old backend result
cannot enter the next graph. Normal outputs retire every3 clocks with ready1.
There is no final-output/input fallthrough; earliest next acceptance is N+1
clocks after final retirement. Input gaps or output stalls have no bound.

## Mathematics and architecture

Let A[u] be final direct successors and R[w] the backend's reflexive reachable
set. For a DAG, form `D[u]=union(R[w] minus {w}, for w in A[u])` and emit
`A[u] minus D[u]`. An edge u→v is discarded exactly when another direct
successor w reaches v, giving an alternative path of length at least two.
The reflexive w bit must be excluded or every edge would erase itself.
Cycles are rejected before applying this formula. In a DAG this is the unique
transitive reduction; every retained edge is essential to reachability.

One local adjacency bank, one captured closure bank and one reduced-row bank
each have a synchronous single read OR write per edge. No vendor primitive,
external memory or N-by-N combinational closure network is introduced.
Each source row scans N successor bits; only actual direct successors read a
closure row. A second N-bit scan shares a scalar counter for degrees/totals.
All reduced rows are committed before any public row is replayed.

The unchanged backend adds two more synchronous banks. Full source declaration
budgets, including its unused public registers, are in [COST.md](COST.md).
Total RAM is1664 default /22656 maximum logical bits; declared scalar storage
is487 /1487 bits. These are source counts, not LUT/FF/BRAM/DSP measurements.
Structural risk is LOW default /MEDIUM maximum because of row-wide masks,
selectors and shallow wide-memory mapping. Device fit remains unmeasured.

Conservative first-valid bound after accepted tail is `7N^2+12N+8` clocks,
1992 at default /29448 at maximum, without external waits. This includes all
backend output collection and full reduction before replay. Backpressure can
delay backend collection only through the stated owner schedule, while public
response stalls add arbitrary time. No hardware-rate claim is made.

## Fixed finite verification plan and offline use

Five profiles N1/2/7/16/64 with tags1..32 use two main replay modes and one
reset simulation each. The plan contains28 children: one fixed certificate
check, version, two lint, five compiles, fifteen simulations, four named
parameter rejects. Each compiler/simulator process tree has a hard20s limit.
First failure/timeout stops; original sources, raw streams and NOT_RUN records
are archived. No adaptive split, seed search, timeout increase or retry exists.

The independent reference uses Kahn deletion for cycles, per-edge-deletion BFS
for minimality, and BFS closure equality for the resulting subgraph. It does
not use the RTL union formula, Warshall recurrence, or the backend's oracle.
The fixed main set includes all16 N2 matrices, dense reverse-numbered DAGs,
diamonds/shortcuts, disconnected/empty cases, exact updates/deletions, loops,
cycles, masked illegal endpoints and atomic invalid32-bit errors. Tests check
every backend closure bit, every reduced row/count/tag, physical synchronous
RAM writes/reads and read ownership, stable held source/output, and first-valid
bounds. Reset predicates name wrapper/backend states, interior bit/row,
held normal/error output, real next nonlast offers and retired owner prefix.
Each cancellation is followed by a full independent fresh graph, not just an
empty handshake. See the generated immutable TEST_PLAN and fixtures for exact
case/target counts. The presence of this description is not a PASS receipt.

`files.f` and `example/files.f` are package-relative and explicitly include
the unchanged sibling dependency. No network, Python or generated table is
needed to instantiate the core. `example/dag_reduce16.sv` exposes every port.
Package LICENSE/NOTICE cover original contributions; upstream comparison and
fixed dependency hashes are in [SOURCES.md](SOURCES.md).

# Exact positive-weight undirected Steiner tree

SOURCE_ONLY / RTL_CANDIDATE / HW_UNVERIFIED. Preparation, numerical reference,
lint, compilation and simulation are NOT_RUN. No synthesis, PnR, STA or board
evidence is claimed. The source-only package is frozen by AUTHOR_SEAL.json.

The core selects a minimum-total-weight connected tree spanning an arbitrary
runtime terminal bitmap, optionally introducing other vertices. It emits the
complete original-edge witness. An all-vertex MST, independent shortest routes,
or directed spanning arborescence does not implement this objective.

Parameters are NUM_NODES=2..16 (default8), MAX_TERMINALS=1..min(6,NUM_NODES)
(default4), WEIGHT_W=1..24 (default16) and TAG_W=1..32 (default8). Included edges
have unsigned strictly positive integer weight; absent weight bits are ignored.
Zero-weight included edges reject the complete frame. Cost width is
WEIGHT_W+ceil(log2(NUM_NODES)); no rounding, saturation or numerical tolerance.
Invalid parameter domains instantiate named missing modules.

Input consists of exactly E=N*(N-1)/2 ordinary ready/valid beats, in ascending
upper-triangle order: (0,1)..(0,N-1),(1,2)..(N-2,N-1). `s_present` and `s_weight`
describe that implicit unordered pair. `s_last` must be high only on beat E-1.
An early/missing last flags an error and still drains exactly E beats. There is
no variable edge-list tail, coordinate input or duplicated edge policy.
Only the first accepted beat captures `s_terminals` and `s_tag`; later values
are ignored. Terminal popcount must be1..MAX_TERMINALS.

One rising-edge clock and synchronous active-high `rst` cancel all ownership
and held outputs; ready/valid are masked during reset. Reset must span a clock
edge before use. No public CE, CDC, external memory or live configuration bank
exists. A source holds every input field while valid&&!ready. The matrix writes
both directions in two private write states between input handshakes. All
off-diagonal words are overwritten before solving; diagonal words are unused.
RAM contents are not reset. Every active DP row is initialized before reads.

One frame owns the module through final summary acceptance. New input can be
accepted on the following edge, never on the summary retirement edge. Unbounded
source pauses or output stalls remove unconditional wall-time guarantees.

Output is each selected original edge once in lexicographic(u,v) order, then
one final `m_summary=1` token. For edges, m_u/m_v/m_weight carry original data.
For the summary those fields are zero. Every token repeats settled total cost,
selected edge count, participating vertex bitmap, captured terminal mask/tag,
feasibility and error flags. All fields stay stable while valid&&!ready.
Payload is unspecified while valid is low.

Error bits: bit0 bad terminal count; bit1 included zero weight; bit2 misplaced
last; bit3 internal descriptor/trace limit error. Invalid frames return only a
summary with feasible0/cost0/count0/vertices0. A valid disconnected terminal set
returns the same empty shape with error0. One terminal returns feasible1/cost0/
count0/vertices equal its sole terminal. A normal feasible tree emits at most
N-1 edges. No invalid frame is presented as a partial-graph optimal answer.

Terminal IDs compact ascending. Numeric masks ascend; proper unordered splits
ascend; equal costs retain their first candidate. Dijkstra chooses lowest-ID
minimum unsettled vertex and relaxes ascending targets. Final root is lowest
ID attaining the minimum full-mask score. The witness is reproducible; no
global lexicographic optimum is promised.

Two scheduled synchronous single-port banks store the mirrored matrix and
packed terminal-subset DP rows. A shared extended adder/comparator serializes
merge and relaxation. Every candidate adds in SW+1 bits; high-carry candidates
are rejected before narrowing. Positive weights support finite iterative
traceback, bounded pending stack, no duplicate positive edge occurrences and a
tree witness. See AUTHORING_CONTRACT.md for the currently frozen mathematical,
width, reset, fixed-profile and once-only preparation requirements. The complete
MATHEMATICS/COST/TB/guard sources are present. All preparation, lint, compilation
and simulation remain NOT_RUN pending independent review and separate approvals.

Both files.f lists interpret entries relative to this package root, including
example/files.f. The all-port default wrapper is example/steiner8.sv. There are
no external RTL/include/memory initialization dependencies.

# Exact state, ownership and trace argument — SOURCE_ONLY

For nonempty terminal subset S and vertex v, D[S,v] is the minimum cost of a
connected original-edge subgraph containing v and every terminal in S. A
separate valid bit represents infeasibility. Weights are positive integers.
An optimal connected subgraph is a tree: removing a positive cycle decreases
cost and preserves connectivity. It has at most N-1 edges.

Singleton initialization has value0 at its terminal and is invalid elsewhere.
For one numeric mask, complete all proper-partition merges at every vertex,
then close the resulting seeds under graph shortest paths. Every candidate
expands to a connected feasible union, whose distinct-edge cost is at most
the candidate's additive descriptor cost. An optimal rooted tree either
starts with a path to a terminal/branch, or splits terminal demand into proper
nonempty subtrees at the root of that path. This gives a merge-plus-path
candidate with cost no greater than the optimum. Together these inequalities
establish exact state values, by induction over proper terminal masks.

The implementation scans all numeric splits1..mask-1, accepting only proper
submasks split<(mask xor split); hence every unordered proper partition occurs
once. Singletons have no proper partition. Dijkstra uses all valid merge seeds
as initial distances. A selected source is marked settled before ascending
target relaxation. Only unsettled targets may change. Positive edges make a
MOVE parent strictly cheaper and settled/immutable. Proper MERGE children are
finalized smaller masks, also immutable.

Masks, accepted splits, selection vertices and relaxation targets ascend.
Equal scores do not replace descriptors. The final root scan retains the
lowest-ID minimum full-mask state. This is a deterministic scheduling rule,
not a global lexicographic witness objective.

Let SW=W+ceil(log2 N). Every optimal state, when feasible, has a simple tree
cost <=(N-1)*(2^W-1)<2^SW. Two child scores may nevertheless sum beyond SW:
the fixed N8 shared-branch graph has a12M merge trial at root0, but7M optimum
for terminals0,6,7. Both merges and score+edge moves use zero-extended SW+1
arithmetic. The high carry rejects a candidate before narrowing. A candidate
outside SW cannot be a feasible state's optimum, so rejection preserves exact
optimality. There is no sentinel saturation, modular cost wrap or tolerance.

BASE records a singleton at its actual compacted terminal. MERGE stores a
proper split. MOVE stores its original-edge settled predecessor. The iterative
trace validates mask/type/base and positive present edges; parent score plus
edge must equal the current score in SW+1 bits and parent score must decrease.
Each accepted MOVE marks one upper-triangle edge bit and both endpoints.

Pending tasks and the current task have disjoint nonempty masks partitioning
terminal demand. MERGE replaces one task by two disjoint children, so at most
t tasks are live, at most t-1 pending. K stack entries suffice. A fixed-mask
MOVE chain never repeats a vertex and has at most N-1 moves. There are2t-1
mask segments in the binary merge skeleton, so descriptor visits are bounded
by N*(2t-1)<=176. The controller rejects before a177th descriptor action.

At the final optimal state, expanded union cost <=descriptor optimum, while
terminal feasibility implies union cost >=optimum. Equality follows. Any
duplicate positive edge occurrence or positive cycle would make a cheaper
feasible union, contradiction. Therefore the bitmap union is a tree with
exact optimum cost and at most N-1 edges. The sharper valid-trace visit bound
is (N-1)+(t-1)+t=N+2t-2<=26; the hardware keeps the conservative176 bound.
No output starts until the complete trace and edge-count scan finish. Internal
descriptor/stack/work failure therefore returns an error summary without
publishing a partial witness.

The matrix bank receives every off-diagonal pair twice, through separate
scheduled writes, before solving. Diagonal words are never read. Each active
DP mask initializes all N rows before merge/closure reads; only fully
finalized proper masks are referenced. mask0 is allocated and unused. Settled
flags reset on first mask and every subsequent mask. Reset masks memory
requests and cancels controller ownership; a fresh frame overwrites all of
these logical states before use. Unreset stale memory is never a fresh input.

Each bank is a single synchronous read-or-write port. Request states cause
clocked read-q updates; later take states consume them. Write states do not
consume same-address old/new read behavior. All stack entries are written
before a valid pop. Exact address strides are mask*N+vertex and u*N+v, with
N an elaboration constant; non-power-of-two N does not change the row count.

The independent future reference enumerates optional vertex sets and runs
Kruskal on each induced retained graph, accepting only connected retained
sets. The optimal tree's vertex set is enumerated; its induced MST costs no
more, and every accepted MST is a feasible terminal tree, proving equality of
the minimum. It does not share the RTL terminal-subset recurrence. It will
run once during separately approved preparation for named fixed inputs only.
HDL checks stored optimum costs and direct witness certificates, never an
optimizer or regenerated numerical target. No such preparation has run.

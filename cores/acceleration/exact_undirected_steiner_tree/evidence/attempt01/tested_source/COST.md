# Source declaration and cycle budget — unmeasured

Status SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED. No LUT/FF/BRAM/DSP, Fmax, power,
synthesis, placement/routing, STA, board or device-fit measurements exist.

N=NUM_NODES, K=MAX_TERMINALS, W=WEIGHT_W, T=TAG_W; I=ceil(log2 N),
C=ceil(log2(N+1)), S=W+I, E=N(N-1)/2, J=max(1,ceil(log2 E)),
Q=ceil(log2(E+1)), P=ceil(log2(K+1)), R=S+1+2+I+K.

| Declared payload | Formula | N8/K4/W16/T8 | N16/K6/W24/T32 |
|---|---|---:|---:|
| Mirrored edge bank | N*N*(W+1) |1088|6400|
| Packed DP bank | N*2^K*R |3712|41984|
| Bank total | Sum |4800|48384|
| Explicit scalar/stack/read words | Formula below |481|816|

The last row counts actual sequential declarations including state, captured
configuration, source/trace/output words, K pending tasks and both RAM read-q
words. It excludes combinational address/arithmetic signals and the two bank arrays:

    3N+T+S+2C+K*I+12I+Q+J+4W+4K+7R+K*(K+I)+P+E+22.

This is a source bit inventory, not an FF result. FSM recoding, RAM granularity
and synthesis elimination are unknown. StackK*(K+I) is28/60 bits; edge bitmap
E is28/120 bits. There is one explicitly multiplexed S+1-bit addition path and
one S-bit unsigned score comparator. Equality, bit tests and small address/
counter comparisons are additional. Runtime addresses use constant N stride;
upper-triangle bases are elaboration constants. There are no DSP requests,
runtime variable multipliers/dividers, replicated relax lanes or external RAM.

Let t be actual terminal count>=2 and M=2^t-1. Each mask initializes N rows.
For one vertex, BEST_READ/BEST_TAKE/BEST_WRITE cost3 edges, numeric split scan
costs mask edges including its terminating test, and every accepted unordered
proper split adds4 edges (left read/take, right read/take). Summed over masks:

    merge_and_init <= N*(4M+M*(M+1)/2)
                      +2N*(3^t-2^(t+1)+1).

The implementation explicitly charges rejected numeric splits too; it does
not claim every controller step has the arithmetic-only3^t complexity.
One Dijkstra selection sweep costs2N+2 edges, with at most N+1 sweeps. Each
source/target relaxation costs at most7 states, including a changed-row write.
MASK_DONE adds1. Therefore a conservative complete DP bound is

    D = N*(4M+M*(M+1)/2)+2N*(3^t-2^(t+1)+1)
        +M*(2*(N+1)^2+7*N^2+1).

D is11405 at default t4 and204925 at maximum t6. Capture costs at most3E
sampled state edges with always-offered input; compaction addsN+2. Final root
scan adds2N+2, trace is conservatively charged6*176, count/emit scans cost at
most3E+3*(N-1)+3, including always-ready edge/summary retirements. A rounded
inclusive first-input through final-summary conservative bound is

    D + 6E + 6N + 1080,

which is12701 default and206821 maximum sampled edges. Extra reset edges,
missing valid input and held-output delay are outside this internal bound.
Invalid or one-terminal frames bypass DP and obey the same larger bound.
This is state charging, not elapsed runtime, measured throughput or a20s
certification. Fixed normal max-profile cases are pre-grouped before any run.

Default and maximum architectural risk MEDIUM: RAM port scheduling and index/
descriptor muxes matter, but declared banks are bounded below50K logical bits.
Terminal count causes exponential work/storage; no larger K is claimed. Final
clock rate and physical RAM mapping remain UNKNOWN. No old numerical tests or
parameter/input Cartesian enumeration are part of this work.

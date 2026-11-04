# Exact runtime binomial coefficient

`exact_binomial` returns the exact number C(N,K) of K-element subsets of an
N-element set, from two unsigned64 scalar inputs. It suits bounded combinatorial
budgets and subset-count planning. The result is an unsigned integer without
wrapping, saturation, rounding, floating point or a modulo parameter.

MAX_N is1..64 (default32), TAG_W is1..32 (default8). The result `m_value` has
MAX_N bits and the opaque tag has TAG_W bits. Invalid static parameters fail
elaboration with `exact_binomial_invalid_parameters__see_README`.
Validation uses the complete unsigned64 values before narrowing, in this order:

1. N>MAX_N returns value0/error1, regardless of K.
2. Otherwise K>N returns value0/error0.
3. Otherwise K=0 or K=N returns value1/error0, including N=0,K=0.
4. All remaining inputs return exact C(N,K)/error0.

Only N beyond the supported domain is an error. For example N=0,K=2^63 returns
successful zero, while N=2^63,K=0 is rejected even though its low address bits
are zero. Tags echo the actual accepted token in every case.

There is one rising-edge clock, synchronous active-high reset and ordinary
ready/valid. No CE, CDC or configuration port exists. A source holds valid and
all fields until acceptance or reset. One owner blocks inputs through response
retirement. The next acceptance is earliest on the following edge; there is no
ready/valid fallthrough. Every output field remains stable under backpressure.
Reset immediately gates ready/valid low, then cancels the owner and clears all
public registers at its active edge. Payload RAM, read data and private operands
are not reset; initialization and current ownership protect every read. Nothing
from a canceled transaction can be published. Caller stalls can be unbounded.

The engine uses symmetry k=min(K,N-K) after full-width validation. One synchronous
single-port RAM initializes indices0..k to [1,0,...,0]. For each row r=1..N,
j descends from min(r,k) to1, replacing coef[j] by coef[j]+coef[j-1]. Descending
order preserves the previous row's two terms. Each update uses three separate
edges: read current, read previous while capturing current, and write sum.
No read-during-write behavior is assumed. The nine states are IDLE, INIT,
ROW_SETUP, READ_CUR, READ_PREV, WRITE_SUM, RESULT_READ, RESULT_LOAD and OUTPUT.
Two final edges read/latch coef[k]. RAM never resets or shifts as an array.

The invariant after row r is coef[j]=C(r,j) for0<=j<=k, with zero when j>r.
Every coefficient is nonnegative and strictly below2^r for r>=1, so MAX_N bits
hold every value. The MAX_N+1-bit combinational sum has a proven zero carry
before narrowing. The maximum result is C(MAX_N,floor(MAX_N/2)):601080390 at
default32 and1832624140942590534 at64 (over32 bits, below2^61). Runtime row n
fits NW=max(1,clog2(MAX_N+1)); j and k fit KW=max(1,clog2(floor(MAX_N/2)+1)).
Only proven valid values enter these private widths; C(0,0)=1 fits even MAX_N1.

All compute paths use U=k*N-k*(k-1)/2 updates. Exact acceptance-to-first-post-edge
valid latency is N+k+3+3U; every special/error path has latency0. Maximum latency
is1227 at default32 and4755 at64. Without sink stalls the acceptance interval is
latency+2. This is a serial preparation service, without a clock-frequency or
board-throughput claim. A multiplicative recurrence could avoid RAM but requires
wide multiply/divide arithmetic; this implementation chooses small RAM and one
MAX_N+1-bit add path. Production has no data multiply/divide/modulo, DSP, ROM,
vendor primitive, unrolled combinatorial search or sibling dependency.

Logical RAM is `(floor(MAX_N/2)+1)*MAX_N`:544 default /2112 maximum bits. Exact
clocked scalar/read/public declarations total
`3*MAX_N+2*NW+2*KW+TAG_W+5`:131 default /255 maximum bits. This includes the
4-bit FSM, two NW counters, two KW counters, current/read/output values, error
and tag. Source bits are not mapped LUT/FF/BRAM, timing, power or measured fit.
Qualitative risk is LOW default/MEDIUM maximum; RAM inference and the65-bit
maximum add path are unmeasured. Synthesis, PnR, STA, board, expanded tests and
inherited regressions are NOT_RUN. Hardware remains HW_UNVERIFIED.

`files.f` contains the sole production source. `example/files.f` adds complete
independent default and maximum services in subset_count_pair. It is a syntax
and instantiation example, without integration or physical evidence.

MATRIX_FREEZE.json and all fixtures were saved before original HDL. Six
MAX_N/TAG_W profiles1/1,2/3,5/8,16/8,32/8,64/32 include every legal N and every
K0..MAX_N+1, all64 input bits and full-width extrema/priority cases. 7281 main
transactions are split into61 fixed128-row groups before any HDL. The primary
oracle uses exact factorial quotients; all legal N<=10 rows additionally count
every subset bitmap. Maximal central coefficients are actually exercised.
25 immediate observed-boundary resets per profile cover every reachable state,
initialization first/middle/last, first/interior/final RAM updates, final read/load,
held computed/endpoint/zero/error/priority results and first computed result.
MAX_N1 has19 explicit computational aliases; MAX_N2 has two middle/interior
aliases. Every reset is followed by a complete full-capacity central-coefficient
transaction, held and actually retired. The actual next frozen token remains
offered until accepted; all result fields are checked over at least three
stalled edges. RAM ownership/read timing, every exact Pascal update, final row
and exact work-based latency receive independent certificates.

`python -B run_tests.py --freeze-source` binds all final source hashes before the
first compiler. `--run` executes exactly80 frozen children, each hard-limited to
20 seconds. A timeout is terminal with no retry, smaller stimulus, later split or
larger deadline. Ordinary failure first preserves exact all sources, matrix,
source seal, receipt and NOT_RUN suffix; root must authorize the repair scope.
A successful receipt is immutable. `--audit` checks the closure offline without
running HDL. SOURCES.md records complete fixed-source/license preflight and
semantic dedup. Only the actual receipt, never a planned matrix, proves PASS.

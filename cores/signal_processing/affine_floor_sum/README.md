# affine_floor_sum

Compute the exact analytic staircase area
`S = sum(floor((A*i+B)/M), i=0..N-1)` from four unsigned scalars. This suits
discrete affine sampling and lattice-budget calculations without sending N data
items. One owner runs a Euclidean reduction with one shared serial multiply
datapath and one shared restoring divider; production uses no multiplication,
division or remainder operators, RAM, ROM, vendor blocks or sibling dependencies.

`files.f` is the complete production closure. `example/files.f` builds the complete
default/max-width `affine_area_pair` integration with independent backpressure.

| Parameter | Default | Legal |
|---|---:|---:|
| W | 8 | 1..16 |
| TAG_W | 8 | 1..32 |

Illegal parameter values fail elaboration with
`affine_floor_sum_invalid_parameters__see_README`. Inputs `s_n/s_a/s_b/s_m`
are unsigned W bits, and `s_tag` has TAG_W bits. `m_sum` is unsigned 3W bits,
`m_error` is one bit and `m_tag` returns the accepted tag. All have ordinary
ready/valid ownership. `M=0` returns sum0/error1, including `N=0,M=0`;
`M>0,N=0` returns sum0/error0. All positive cases are exact, without wrapping,
saturation or approximation. `M=1` is supported across the whole input range.

`rst` is synchronous active high and immediately gates both ready and valid low.
At its active edge the owner is canceled and public outputs clear. Private
arithmetic registers are initialized by their owner before use and need no reset.
Reset never emits a canceled response. Input remains blocked until the current
response retires; the next acceptance is earliest on the following edge. Every
response field remains stable while valid and not ready. There is no combinational
path from output ready to input ready, and no overlap between owners.

Each round first computes T=n(n-1)/2 with pre-halved factors, adds
T*floor(a/m), reduces a, adds n*floor(b/m), reduces b, and forms y=a*n+b.
If y<m, the result is complete. Otherwise replace n,b by quotient/remainder of
y/m and swap m,a. The denominator is positive and strictly decreases at each
swap; within two swaps it falls below half its previous value. n never increases.
Seven states are IDLE, TRI_SETUP, MUL, MUL_RET, DIV, DIV_RET and OUTPUT.
Each multiply takes W steps and each divide takes 2W steps, even for small data.
MUL_RET/DIV_RET consume fully registered results. The triangular product stays
in the multiplier accumulator during the a/m division, so it needs no extra reg.

For R positive-input rounds, accept-to-first-post-edge-valid latency is exactly
`R*(10W+8)-(2W+1)`. The terminal round uses `8W+7` edges and each preceding
round uses `10W+8`. M0/N0 results have latency0. The safe bound R<=2W+1 gives
`(2W+1)*(10W+7)` edges:1479 at W8 and5511 at W16. This conservative bound
need not be attained. Acceptance interval without stalls is latency+2 edges.

Let U=2^W-1. The maximum result is U^2*(U+1)/2 at N=A=B=U,M=1, strictly
below 2^(3W-1). It is 8,323,200 at W8 and140,733,193,420,800 at W16.
Each nonnegative accumulated contribution is bounded by the original result.
T fits2W bits. After normalization a,b<m, y<2^(2W); all three quotients fit W
bits, including floor(y/m)<=n. The divider holds a W+1-bit trial remainder.
There is no signed arithmetic. These bounds justify every narrowed assignment.

The declared state budget is `17W+9+max(1,clog2(W))+max(1,clog2(2W))+TAG_W`
bits:160 at W8/T8 and322 at W16/T32. This includes all public and private
registers. It describes source storage, not mapped PPA. Shift-add multiplication
uses a 3W-bit adder; restoring division uses a W+1-bit subtract/compare. There
are no DSP/RAM primitive instantiations. Synthesis, PnR, STA, board and inherited
regressions were not run; hardware is HW_UNVERIFIED.

`prepare_matrix.py` froze the entire finite matrix before any original HDL.
Do not regenerate or replace MATRIX_FREEZE.json or its fixtures. Six profiles
(1/1,2/3,3/8,5/8,8/8,16/32) include all 16/256/4096 W1..3 input tuples,
fixed seeded/directed wider values, actual full-width extremes, and Fibonacci
chains. The primary oracle directly enumerates every i in Python integers.
31 reset targets per profile cover all states, first/last multiply/divide steps,
each return, both y branches, deep round and held success/M0/N0/M0+N0 outputs.
W1 has five explicit aliases for unreachable y-division/deep-round boundaries.
Every reset occurs immediately at its observed boundary and is followed by a
complete independently expected fresh transaction, held and actually retired.
The real next frozen input token is held until acceptance; every output field is
checked during at least three stalled cycles. Trace certificates check each
product, division identity, transformed round, sum invariant and exact latency.

`python run_tests.py --freeze-source` binds the source closure before any HDL
child. `--run` executes exactly19 fixed children, each with a hard20-second
limit. TIMEOUT is terminal, without retry, reduction or a longer limit. Ordinary
failure preserves the exact source/plan/receipt and all remaining NOT_RUN names
before root approves a repair scope. `--audit` verifies a successful receipt and
source/fixture closure offline without HDL reruns. See SOURCES.md for the fixed
upstream license/read preflight and originality evidence.

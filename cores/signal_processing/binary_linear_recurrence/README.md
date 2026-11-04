# Shortest finite binary linear recurrence

`binary_linear_recurrence` receives raw one-bit observations and infers one
shortest finite GF(2) recurrence in RTL. It returns the retained length, order,
lag coefficients and the next bit predicted by that returned recurrence.
The caller provides neither taps, discrepancies, a polynomial nor a summary.

Status is **HW_UNVERIFIED**. Only [verification.json](verification.json)
qualifies finite lint and unit-simulation evidence. Synthesis, PnR, STA,
hardware and expanded regression are excluded.

## Finite sequence and coefficient meaning

For retained samples `s[0]` through `s[N-1]`, `m_order=L` is the smallest
nonnegative order for which some binary coefficients satisfy

```text
c[0] = 1
s[t] = XOR(c[i] & s[t-i], i=1..L), for every L <= t < N
m_next = XOR(c[i] & s[N-i], i=1..L)
```

`m_connection[i]` is lag coefficient c[i], with bit zero equal to one on
valid results; all bits above L are zero. Empty XOR is zero. All-zero samples
are valid with L=0, connection=1 and next=0. Arithmetic is exact GF(2), without
rounding, saturation or tolerance.

Finite prefixes can admit multiple shortest solutions. The core returns one
such solution; no lexicographic choice or upstream polynomial compatibility
is promised. In particular, c[L] can be zero. Prefix `10` has minimal order
one and connection=1 (c[1]=0), corresponding to monic characteristic x.
Delay-polynomial degree therefore need not equal L. Prefix `1` has multiple
order-one solutions; this implementation returns connection=3 and next=1.
Prefix `1010` uniquely yields L=2, connection=5 and next=1. Prediction is model
extrapolation; it does not guarantee that future observed bits will match.

## Interface and frame ownership

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid,
no CE, runtime configuration or CDC. A transfer occurs only when valid and
ready are both high on the edge. The source holds all fields stable until
acceptance or reset. `s_keep=0` ignores the bit but retains framing. At least
one beat forms a frame, ending at accepted `s_last`. The first accepted beat
supplies `s_tag`, even when masked; later tags are ignored.

Retain the first MAX_BITS kept observations. Excess kept beats set overflow
and drain without changing history or count; masked beats never overflow.
There is one owned frame and one response. New input remains blocked during
tap work, prediction and the complete held response. Every response field
remains stable under arbitrary backpressure. An output retires on `m_valid &&
m_ready`; the next frame can start on the following edge. Missing tails and
sink stalls have no wall-clock deadline.

| Output | Meaning |
| --- | --- |
| `m_count` | Bounded retained raw-bit count N, including zero bits |
| `m_order` | Smallest finite recurrence order L |
| `m_connection[MAX_BITS:0]` | Inclusive lag-vector c[0] through c[MAX_BITS] |
| `m_next` | Parity predicted from returned coefficients and retained history |
| `m_tag` | First accepted tag |
| `m_errors[0]` | Empty retained sequence |
| `m_errors[1]` | Excess kept observation |

Any error zeros order, connection and next; bounded count and first tag remain.
The error bits are independent predicates. Their simultaneous value three is
unreachable for legal MAX_BITS>=1, since overflow implies a nonempty prefix.
There is no fabricated combined-error test. Overflow rejects the frame even
though a bounded prefix was processed.

Reset gates ready and valid low immediately and synchronously cancels partial
capture, discrepancy taps, updates, prediction and held output. Upstream pending
valid may be canceled by reset. History RAM is deliberately unreset. A new
frame overwrites its retained prefix before any read of that prefix; no old
entry is consumed. No data or response survives a reset.

## Serial architecture, widths and cycle contract

`MAX_BITS` is 1..256 (default64), `TAG_W` is 1..32 (default8).
`CW=max(1,ceil(log2(MAX_BITS+1)))`, up to9. Sample count, order, saved index
and tap use CW unsigned bits. `2L` is formed after extension to CW+1 bits,
then compared with the extended saved index. C and auxiliary P each have
MAX_BITS+1 bits. No signed or fixed-point arithmetic is used.

Online Berlekamp-Massey starts C=1, P=x and L=0. A retained input at index n
is written to history and captured as the discrepancy. Each previous tap
requires one synchronous read and one evaluation edge. On discrepancy one,
C becomes C xor P. If additionally `2L<=n`, L becomes n+1-L and P becomes
old C shifted left one; otherwise P shifts left one. Nonblocking RHS uses
the pre-correction C. This shifted-auxiliary representation avoids variable
polynomial shifts and an extra saved polynomial. All polynomial shifts are
constant one-bit operations. Prediction reuses the same history read port.

States are COLLECT, TAP_READ, TAP_EVAL, UPDATE, FINALIZE, PRED_READ,
PRED_EVAL and EMIT. Collection writes and history reads occupy disjoint
states. Discrepancy reads index n-i, where 1<=i<=L<=n; prediction reads N-i,
where 1<=i<=L<=N. No simultaneous same-address behavior is assumed.

For a retained bit accepted at edge E with prior order L, next retained
acceptance is earliest E+2L+2. Masked and excess collection beats can accept
every edge. The source can add bubbles. If accepted tail edge is E, the first
visible output is exactly the following many periods later:

| Tail kind | First-valid delay |
| --- | ---: |
| Valid retained tail | 2*prior_order + 2 + 2*final_order |
| Valid masked tail | 1 + 2*final_order |
| Rejected tail | 1 |

The maximum valid delay is max(4,4*MAX_BITS-2):254 default,1022 at maximum.
For MAX_BITS>=2 a one at the penultimate position of an otherwise zero full
sequence attains 4*MAX_BITS-2. An output can first transfer on the next edge
after visible valid. These are clock-period counts, with no claimed clock
frequency, board throughput or power measurement.

History plus the two polynomials store 3*MAX_BITS+2 bits:194 default or770
maximum, excluding scalar control, read data, counters and tag. One serial
discrepancy/prediction bit operation and one conditional wide XOR replace
parallel matrix solving. There is no runtime multiply/divide, external RAM,
vendor primitive or sibling dependency. Architecture risk is LOW default,
MEDIUM maximum: the257-bit conditional XOR and variable coefficient selection
can matter physically; a one-bit RAM may use distributed resources. No RAM,
DSP, FF, LUT, Fmax or power result has been measured.

## Offline invocation and frozen finite evidence

Core manifest [files.f](files.f); default example manifest
[example/files.f](example/files.f), top `recurrence64`. Both are relative to
this package directory. The wrapper exposes the same ordinary ready/valid
semantics; CE-qualified streams require their own adapter. Both dependency
closures are local. There are no generated tables or external packages.

Run `python run_tests.py` from any directory using the repository's native
OSS-CAD-suite Icarus binaries. The runner prepends their bin/lib directories,
uses exact native executable paths, and limits every compiler/simulator child
to20seconds. Any timeout is terminal: no rerun, reduced fixtures, larger
timeout, physical flow or expanded regression is permitted. Non-timeout
failures may be repaired and the identical matrix rerun; failures are retained.

Before its first tool check, the runner freezes six complete deterministic
fixture sets, their hashes and20 named reset targets. Profiles are
(MAX_BITS,TAG_W)=(1,1),(3,3),(5,8),(17,8),(64,8),(256,32). The19 commands are
one version query, two strict syntax checks, six compile/sim pairs, and four
named invalid-parameter rejects: MAX_BITS0/257 and TAG_W0/33.

The fixed fixtures include exhaustive binary sequences of lengths1..8 for
M1/3/5 and1..9 for M17, empty/masked frames, zeros, ones, alternating bits,
one-hot positions including late order growth, `10` trailing-zero coefficient,
full capacity, overflow drain, tags, masked tails,35 capacity-bounded random
frames and20 mixed random frames per profile, and full seeded-recurrence cases.
Some exhaustive/direct/random frames overflow smaller capacities; random
capacity-bounded frames can be all zero and remain valid.

The independent oracle builds GF(2) linear equations for every candidate L
in increasing order and uses Gaussian elimination to find the first consistent
system. It does not reproduce BM updates. Every emitted connection satisfies
all equations from t>=L, c0=1, above-L zeros and next-bit parity. Unique systems
require the exact vector; nonunique systems accept any valid minimal vector.
The final and prior independent orders also determine exact tail latency.

Every profile executes20 observed-state resets followed immediately by20
complete fresh analytic frames: all eight states, first/middle/last taps,
jump/nonjump/zero-discrepancy updates, genuinely held valid/empty/overflow
results with blocked source, overflow drain and partial capture. Reset is
asserted on the observation's negedge before another active edge. Fresh
recovery is `1` at M1, `101` at M3, or `1010` otherwise, with metadata, full
coefficients, prediction, hold, retirement and no-stale-output checks.
At M1 discrepancy tap states are unreachable and four tap targets alias
UPDATE; discrepancy nonjump aliases zero-discrepancy UPDATE. Middle/last
prediction taps coincide at order one. These remain20 reset/fresh pairs,
not20 distinct internal states. The exact list is in the runner/report.

Main frames, beats, oracle equations, output latencies and observed trace hashes
exclude probe/setup/recovery traffic. Tap, prediction, held-cycle and source-
stall counters include all traffic, including reset setup and fresh recovery.
The report records finite evidence only; it does not establish exhaustive
parameter/sequence correctness or physical implementation.

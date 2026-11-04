# Exact algebraic Kendall tau-b rank association

`kendall_tau_b` receives raw signed `(x,y)` observations and computes their
tie-aware ordinal association in RTL. It returns exact signed score S and
unsigned radicand R representing **tau_b=S/sqrt(R)**, together with the
five mutually exclusive unordered-pair populations. The caller provides
neither ranks, a sorted list, tie counts, pair classes nor a correlation.

Status is **HW_UNVERIFIED**. Only [verification.json](verification.json)
qualifies the recorded finite lint/unit simulations. Synthesis, PnR, STA,
hardware and expanded regression are excluded.

## Exact algebraic and tie contract

For retained points i<j, equality is tested before ordinal direction:

| Pair class | Condition | Output |
| --- | --- | --- |
| Concordant C | Both axes differ and their order directions agree | `m_concordant` |
| Discordant D | Both axes differ and their order directions differ | `m_discordant` |
| X-only tie Tx | x equal and y different | `m_tie_x` |
| Y-only tie Ty | y equal and x different | `m_tie_y` |
| Joint tie Txy | x equal and y equal | `m_tie_both` |

All unordered observation pairs contribute once, regardless of arrival order.
Equal axes are neither concordant nor discordant. Repeated points contribute
their multiplicities. With N retained points:

```text
P = N*(N-1)/2 = C+D+Tx+Ty+Txy
S = C-D
A = P-(Tx+Txy) = C+D+Ty   # pairs untied in x
B = P-(Ty+Txy) = C+D+Tx   # pairs untied in y
R = A*B
m_pairs=P; m_score=S; m_radicand=R
tau_b = S/sqrt(R), when R>0
```

Both the score and radicand are calculated in RTL. This exact algebraic
representation handles irrational values without approximation. It is not
a floating-point or fixed-point scalar. There is no division, square root,
rounding, saturation, clipping, p-value, significance decision, tie-breaking
by arrival index, tau-c or inferential assumption. A later scalar conversion
owns its quantization. S can be zero with R positive, a valid zero association.
Every valid result satisfies S*S<=R and represents a value in [-1,1].

For `(-1,-1),(0,0)`, P=C=S=R=1 and tau_b=1. Reversing only y gives S=-1,
R=1. The three points `(-1,-1),(0,1),(1,-1)` give C=D=Ty=1, S=0 and R=6.
The triple `(-1,-1),(-1,-1),(0,0)` has C=2,Txy=1,S=2,R=4 and tau_b=1.
Identical points, a constant axis, a singleton or an empty retained sequence
have R=0, so tau-b is undefined and explicitly rejected.

Permuting complete observations preserves all outputs. Exchanging x and y
swaps X-only/Y-only ties while preserving S and R. Reversing the strict order
of exactly one axis swaps C and D and negates S. Strict monotone relabelings
preserve the corresponding order/tie relations; numeric magnitudes are not
used. These are rank-association semantics, distinct from paired-difference
signed ranks, cross-group U, slope estimation and categorical partition ARI.

## Framing, capacity, independent errors and reset

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid,
no CE, CDC or runtime configuration. A transfer occurs on `s_valid && s_ready`.
Hold valid and all source fields until acceptance or reset. A frame contains
at least one accepted beat and ends at accepted `s_last`. Only `s_keep=1`
retains a point. Masked x/y are ignored while preserving framing. The first
accepted beat supplies `s_tag`, even when masked; later tags are ignored.

Retain the first MAX_LEN kept observations. Kept excess beats set overflow
and drain without writing RAM, comparing samples or changing retained count
or coordinate-variation predicates. Masked excess beats do not overflow.
The entire frame is rejected on overflow; no partial-prefix metric is emitted.

| Error bit | Predicate over the retained prefix |
| --- | --- |
| `m_errors[0]` | Fewer than two distinct x values, including N<2 |
| `m_errors[1]` | Fewer than two distinct y values, including N<2 |
| `m_errors[2]` | At least one excess kept point was accepted |

The three flags are independent and all eight patterns are reachable for
every legal MAX_LEN>=2. Empty/singleton prefixes have bits0/1 set. Constant
x with varying y sets only bit0, and vice versa. Drained tail coordinates
cannot rescue a constant retained axis. Any error zeros **all** public pair
populations, score and radicand. Bounded `m_count`, first tag and error bits
remain diagnostic; internal prefix pair populations are not published.

There is one owned frame and one response. Input is blocked during each scan,
final multiplication and the complete held response. Every output field is
stable under arbitrary sink backpressure. An output retires on `m_valid &&
m_ready`; the next frame can first enter on the following edge. Missing tails
and sink stalls have no wall-clock bound.

Reset gates ready and valid low immediately. Its active edge cancels partial
capture, synchronous reads, classification, multiplication, held response and
pending source offers. It clears scalar control and output arithmetic. RAM and
its read-data register are unreset: every subsequently read prefix entry is
overwritten by the new frame before use. Read states always precede consuming
states, so stale read data cannot enter a result. No canceled response is emitted.

## Widths, scheduling and structural budget

| Parameter | Default | Legal domain |
| --- | ---: | --- |
| DATA_W=W |16|1..32, signed two's-complement x and y |
| MAX_LEN=M |32|2..256, including nonpowers of two |
| TAG_W |8|1..32 |

CW=ceil(log2(M+1)), AW=max(1,ceil(log2 M)), Pmax=M*(M-1)/2,
PW=max(1,ceil(log2(Pmax+1))) and LW=max(1,ceil(log2 PW)) are derived widths,
not public overrides. Counts need CW bits and RAM scan addresses AW bits.
Each pair population and factor A/B is 0..Pmax, using PW bits (9 default,
15 maximum). Intermediate factor sums are explicitly PW+1 bits. The score
is formed by extending C and D before signed subtraction to PW+1 bits:
-Pmax<=S<=Pmax. R<=Pmax squared fits exactly in 2*PW unsigned bits,18 default
and30 maximum. At M256, Pmax=32640, S fits signed16 and R<=1065369600.
No machine-size approximation is used by RTL.

Online collection writes one 2W-bit sample and captures it in registers.
Each prior sample then takes one synchronous SCAN_READ and one SCAN_EVAL
edge. Direct signed comparisons classify the pair; subtraction or products
of raw coordinates are unnecessary, including at signed minima/maxima.
One shared sample read port addresses only `[0,prior_count)` and excludes
the just-written sample. Reads and writes occupy disjoint states, so no
RAM collision mode is assumed. No sorting network or all-pairs storage exists.

After FINISH_SAMPLE and FINALIZE, a valid frame initializes a serial unsigned
shift-add multiplier for A*B. It performs exactly PW bit steps, including
leading zeros, then publishes R. The accumulator and shifted term are 2PW
bits; the multiplier is PW bits and step counter LW bits. Every intermediate
sum is bounded by the final nonnegative product; shifted terms fit 2PW bits.
No runtime multiply/divide operator, square-root engine, vendor primitive,
external memory or sibling RTL is required. MAX_LEN products/division by two
appear only in constant elaboration width calculations.

The seven states are COLLECT, SCAN_READ, SCAN_EVAL, FINISH_SAMPLE, FINALIZE,
MUL_RUN and EMIT. If a retained point is accepted at E with q prior retained
points, the next retained acceptance is earliest E+2q+2. Masked/excess beats
can accept every collection edge. Tail acceptance to first visible valid:

| Tail and result | Delay in clock periods |
| --- | ---: |
| Valid retained tail | 2q+2+PW |
| Valid masked tail | 1+PW |
| Rejected retained tail | 2q+2 |
| Rejected masked/excess tail |1|

Maximum valid first-delay is 2*M+PW:73 default or527 maximum. Complete online
classification performs exactly N*(N-1)/2 read/evaluate pairs, even when the
eventual result is rejected for a constant axis or overflow. Source bubbles
add occupancy. Earliest output transfer is the edge following visible valid.
These are RTL period schedules, without a measured clock or hardware rate.

Logical sample RAM stores 2*W*M bits:1024 default /16384 maximum. Scalar,
read-data and output declarations store `12+6*W+2*CW+AW+TAG_W+14*PW+LW`
bits:263 /476. These counts exclude combinational wires and do not predict
mapped RAM/LUT/FF/DSP quantities. Qualitative risk is LOW default / MEDIUM
maximum, from RAM mapping,32-bit signed comparisons, pair-count accumulation
and30-bit serial-product addition. There are no measured area, frequency,
power, device-fit or board-throughput results.

## Offline use and frozen finite evidence

Core manifest [files.f](files.f); complete default wrapper manifest
[example/files.f](example/files.f), top `association32`. Manifests resolve
from this package directory and need no generated table, include, external
RAM, Python package, network or untracked sibling. The wrapper preserves
ordinary ready/valid; older CE-qualified streams require their own adapter.

Run `python run_tests.py` from any directory. The standard-library runner uses
exact repository-native OSS-CAD-suite Icarus/vvp paths and prepends bin/lib.
Every compiler/simulator child has a20-second hard limit. A timeout is terminal:
stop, preserve TIMEOUT/NOT_RUN and refuse rerun, fixture shrinkage or larger
limit. An ordinary failure can be fixed and the identical matrix rerun, with
the failed source hashes/tool records retained in `prior_failed_attempts`.

[TEST_PLAN.json](TEST_PLAN.json) is written before the first compiler/simulator.
The runner generates all six full fixture sets, freezes their digests and
records the20 reset targets before its first tool check. Profiles W/M/T are
1/2/1,3/3/3,8/5/8,16/17/8,32/64/32 and32/256/32. The21 commands are one version,
two strict syntax checks, six compile/sim pairs and six named static rejects:
W0/33, M1/257 and T0/33. No automatic physical or expanded flow follows.

Fixed cases cover signed extrema, all five pair classes, repeated observations,
positive/negative/zero scores, exact plus/minus one, all eight error patterns,
full increasing/decreasing/constant-axis/both-constant/block-tied populations,
maximal radicand, masked first/tail, four prefix overflow types and tags.
W1 enumerates all sequences of lengths1..5 from its four raw point choices.
M3/M5 enumerate lengths1..3 from nine three-level raw point choices. Selected
point reversals and axis exchanges are explicit fixtures. Each profile also
has35 capacity-bounded random and20 mixed random frames. Random frames may
be degenerate or overflow, according to their actual retained prefix.

The independent oracle lexicographically sorts (x,y), then counts strict y
inversions with merge-sort. Equal-x groups have sorted y and contribute no
inversions. Marginal/joint multiplicity choose-two counts supply ties; integer
algebra derives C,S,R. It does not mirror the RTL's pair classifier or serial
multiplier. Every complete public result and its exact tail delay is checked.
All six internal bounded-prefix populations are also compared, including
canonicalized-error frames. Expected total pair evaluations and PW-step products
are checked, and each observed result trace is independently compared again
and SHA256-bound. This is finite evidence, not a proof over the entire domain.

Twenty observed-phase resets/profile cover every state, first/middle/last
scan/multiplier phases, all five classification branches, partial capture,
overflow drain and genuinely held valid/degenerate/overflow responses with
blocked source. Reset is asserted on the observing negedge before another
active edge. At M2 the one prior scan is first/middle/last; PW1 multiplication
first/middle/last steps coincide. There are20 reset/fresh pairs, without
claiming20 distinct internal states. Every reset is followed immediately by
the complete valid analytic `(-1,-1),(0,0)` frame, checking all fields, first
tag, hold, retirement and no stale output.

Frame/beat/latency totals, public-oracle coverage, prefix pair checks and main
multiplier counts exclude probe/setup/recovery traffic. Scan, multiplier,
held-cycle and source-stall trace counters include all traffic. These scopes
are distinct in the report. No previous package or B14 timeout is modified.

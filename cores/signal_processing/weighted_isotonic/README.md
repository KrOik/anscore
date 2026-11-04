# Exact weighted isotonic regression

`weighted_isotonic` fits an ordered sequence with a nondecreasing, piecewise
constant response. It implements weighted pool-adjacent-violators regression
in RTL and returns the maximal constant blocks as exact rational means.
Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Only the bounded local checks recorded in `verification.json` are qualified.

## Mathematical and membership contract

For the retained kept input sequence x[0..n-1], with strictly positive integer
weights w[i], the unique fitted vector minimizes

```text
sum_i w[i]*(y[i]-x[i])^2   subject to y[0] <= ... <= y[n-1].
```

Input order is the ordinal/covariate order supplied by the caller. The core
does not sort observations by value or combine equal abscissas. Masked beats
are absent from the regression; indices refer to the densely numbered kept
sequence. If observations need sorting by a separate coordinate, that is an
upstream operation.

Every successful output token describes one consecutive block:

- `m_start` is its zero-based kept-sequence start and `m_length` its size.
- Its fitted value is exactly `m_numerator/m_denominator`, with signed
  numerator sum(w*x) and positive denominator sum(w) over that block.
- Every member gets this same fitted value. Blocks cover [0,n) exactly once
  in input order. `m_count=n`, `m_block_count` is the number of blocks and
  `m_block_index` starts at zero. `m_last` identifies the final block.

Adjacent equal means are merged as well as decreasing means, so successful
block means are **strictly increasing** and each reported block is maximal.
Fractions are not reduced: an all-one sequence can return numerator=weight
sum and denominator=weight sum, rather than 1/1. No division, rounding,
fixed-point approximation, saturation or arithmetic wrapping occurs. The
numerical error in the returned rational fitted vector is zero for every
legal error-free frame. A caller converting the fractions to a finite numeric
format owns that later quantization contract.

## Frame, error and reset protocol

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid,
no CE, CDC or runtime configuration. An accepted `s_last` ends the frame;
every frame contains at least one accepted beat. Only `s_keep=1` contributes
a member. The first accepted beat supplies the frame tag, even when masked;
later tags are ignored. The source holds all fields until `s_valid&&s_ready`.
All output fields stay stable until `m_valid&&m_ready`.

Only one frame is owned at a time. It is fully collected and solved before
the first output token is presented, and a new frame waits for the final
token to retire. A missing tail waits for further input or reset, without a
timeout or implicit frame split. No prefix solution can escape a rejected
frame.

| `m_errors` bit | Meaning |
| --- | --- |
| 0 | Empty: no retained kept members |
| 1 | Capacity: at least one kept member beyond `MAX_LEN` was accepted |
| 2 | Zero weight on any kept member, including excess drain beats |

Errors are independent sticky predicates, not a priority status. A zero-weight
member rejects the complete frame; it is not silently excluded. A masked
zero weight is harmless. The first `MAX_LEN` kept beats determine the bounded
diagnostic `m_count`, including zero-weight members; later kept beats cannot
wrap it. Capacity/domain errors stop unnecessary arithmetic and drain through
the accepted tail while still checking zero weights.

An erroneous frame returns exactly one `m_keep=0,m_last=1` token. Numerator,
denominator, start, length, block count and block index are zero. Its first
tag, retained diagnostic count and all error bits remain meaningful. A
successful frame has `m_keep=1,m_errors=0` on every block token.

Reset immediately gates public ready/valid low. An active reset edge cancels
the partial frame, comparison, pending memory write, output read, held token
and a pending input offer. It clears count/depth and control, making every old
stack word unreachable. Payload RAM is not reset. Each newly live entry is
written before it can be compared/read; the next frame starts at depth zero.
No canceled result is returned. Outputs have transaction meaning only while
valid. Reset is the only abort operation.

## Widths and bounded architecture

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DATA_W=W` | 16 | 1..24, signed two's-complement values |
| `WEIGHT_W=G` | 8 | 1..16, unsigned weights; zero is a frame error |
| `MAX_LEN=M` | 16 | 1..64, including nonpowers of two |
| `TAG_W` | 8 | 1..32 |

Derived widths are local and cannot be overridden: L=ceil(log2(M)), zero for
M=1; C=max(1,clog2(M+1)); PW=W+G+1; SW=PW+L; TW=G+L. Outputs use SW numerator,
TW denominator and C-bit indices/counts. Illegal public parameters fail
elaboration via `weighted_isotonic_invalid_parameters`.

The input multiplication is signed W by a G+1-bit positive weight, retaining
its complete PW-bit product. A block of at most M members has

```text
abs(S) <= M*2^(W-1)*(2^G-1) < 2^(W+G+L-1) = 2^(SW-2)
0 < T <= M*(2^G-1) < 2^TW
```

Thus all disjoint-block merge sums fit SW/TW, and lengths/counts through M fit
C. Magnitude cross products have their complete SW+TW bits. Partial serial
product sums are nonnegative and bounded by their full product, so they also
fit. Default numerator/denominator/cross widths are 29/12/41; maxima are
47/22/69. The minimum negative input and unsigned maximum weight are legal.

A synchronous single-read/single-write packed stack stores {S,T,length} for
each live block. A new member is pushed, then the top adjacent pair is merged
while its left mean is greater than or equal to the right mean. Merging writes
the lower entry and reduces depth; stale upper entries are inaccessible.
Two separate synchronous reads precede comparison; no read/write collision
value is required. Once solved, the stack is streamed in order.

One natural-width value-by-weight multiplier has a separate product register.
For same-sign block means, one conventional serial multiply adder computes
abs(SL)*TR and abs(SR)*TL in two TW-cycle rounds, retaining both exact products.
Negative pairs reverse magnitude ordering; different signs bypass the products.
The implementation does not instantiate a divider, parallel cross-product
multiplier pair, vendor primitive, generated table or external RTL dependency.

Logical stack storage is M*(SW+TW+C): **736 bits** at defaults and **4,864 bits**
at maximum, excluding scalar control, read/output and comparison registers.
Qualitative resource risk is **LOW** by default, **MEDIUM** at maximum because
of the 24-by-17-bit input multiplication, 69-bit serial adder and memory mapping.
No measured resource count, frequency, power or device-fit result is claimed.

Each push creates at most one new block; at most n-1 merges and n-1 ordered
pair exits occur, so at most 2n-2 pair comparisons are needed per successful
frame. Input II is variable, at least four clocks for a processed positive
member; masked/error-drain beats can transfer each clock. A conservative bound
from final input acceptance to first valid token is (2*TW+12)*M+20 periods,
including tail repairs and output RAM access. Subsequent block tokens become
valid two periods after the previous transfer (three-edge transfer II with an
always-ready sink), checked in the finite TB. The next frame can enter one
period after the last token transfers. Endpoint stalls remove any unconditional
wall-clock retirement bound. No sample-per-clock regression claim is made.

## Offline use and finite verification

Both manifests are relative to this package root:

```text
iverilog -g2012 -Wall -tnull -s weighted_isotonic -f files.f
iverilog -g2012 -Wall -tnull -s monotone_calibration16 -f example/files.f
python -B run_tests.py
```

The example fits up to 16 ordered signed16 calibration observations with
unsigned8 weights and forwards every exact block/membership/error field.
It is an integration candidate by syntax compilation only. The complete
closure is one local production source plus the optional example; no sibling,
untracked support, network, memory image or build-time generator is needed.
All new work is covered by root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE); actual source/license preflight is in
[SOURCES.md](SOURCES.md).

The independent Python oracle uses the exact max-min characterization

```text
y[i] = max(a<=i) min(b>=i) sum(j=a..b,w[j]*x[j])/sum(j=a..b,w[j])
```

with Fraction arithmetic, not a PAVA stack. Every valid frame checks monotone
feasibility and the KKT conditions: prefixes of sum(w*(y-x)) are nonpositive,
the final prefix is zero, and every strict block boundary has zero prefix.
For n<=5, independently enumerated contiguous partitions and their exact
weighted squared losses cross-check the fitted vector. Equal fitted levels
are grouped only for expected output membership and unreduced block sums.

Six finite profiles include signed1/weight1/length1, exhaustive signed2 with
weights 1..3 and lengths 1..3, nonpower lengths 5/7, the default and the maximum
configuration. Fixtures cover increasing/decreasing/equal/alternating values,
close rational comparisons, both signs and zero, extreme products, unreduced
means, empty/masked frames, exact capacity, masked excess, overcapacity,
zero weights in retained/excess beats, simultaneous errors, tags, bubbles,
real source stalls and held outputs. Every output field is compared; normal
block intervals must cover the complete kept sequence exactly once.

Reset probes immediately cancel each reachable controller-state condition,
including the middle of the second serial product, pending stack writes,
output reads and genuinely held normal/error tokens with stalled input offers.
Separate probes cancel domain/capacity drain. Each is followed by a checked
fresh singleton that overwrites and reads stack storage. No active edge occurs
between observing the targeted condition and `reset_now`. These finite probes
are not exhaustive state-space proofs. Eight illegal static settings are
explicitly rejected. Every subprocess is limited to 15 seconds; only local
Icarus/vvp and Python's standard library run. Temporary vectors/executables are
removed automatically; verification records actual commands, outputs, source
SHA256 and vector hashes. Positive diagnostics fail. Package text is UTF-8/LF.
No synthesis, PnR, STA, board test or expanded regression has run.

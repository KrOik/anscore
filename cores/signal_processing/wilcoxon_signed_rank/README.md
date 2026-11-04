# Exact paired Wilcoxon signed-rank statistic

`wilcoxon_signed_rank` accepts raw unordered signed `(x,y)` observation pairs,
forms `d=x-y` in RTL, removes exact zero differences, and computes the positive
and negative sums of average ranks of `abs(d)`. It returns exact doubled rank
sums and their two-sided minimum. The caller supplies neither differences,
ranks, sorted magnitudes nor sufficient statistics.

Status is **HW_UNVERIFIED**. Only [verification.json](verification.json)
qualifies recorded finite lint/unit-simulation checks. Synthesis, PnR, STA,
hardware and expanded regression are not run by this package.

## Exact rank and zero contract

Retain the first MAX_LEN kept pairs, including pairs with x=y. For each retained
pair compute d=x-y. Remove all d=0 before ranking (the Wilcox zero convention).
Let n be the number remaining. Rank their absolute differences from 1 through
n in ascending order. A group of equal magnitudes receives the exact average
of its occupied ordinal ranks. Sign does not split a magnitude tie.

```text
Wplus  = sum(average rank of |d| for d>0)
Wminus = sum(average rank of |d| for d<0)
m_plus2  = 2*Wplus
m_minus2 = 2*Wminus
m_stat2  = 2*min(Wplus,Wminus)
```

These unsigned integer outputs retain every half-rank exactly. No division,
rounding, saturation, random tie breaking, approximate rank, tolerance or
floating point occurs. A valid frame satisfies
`m_plus2+m_minus2=n*(n+1)`. For example, differences `[1,-1,3]` have ranks
`[1.5,1.5,3]`, so plus2=9, minus2=3 and stat2=3. Swapping x and y swaps the
directional sums and preserves stat2. Permuting complete pairs preserves every
statistic. A single nonzero difference is valid, with two-sided statistic zero.

`m_tied` counts nonzero differences belonging to a magnitude group of size at
least two. It counts members, not groups, and is zero or at least two. Zero
differences do not enter a tie group and do not shift the retained nonzero
ranks. `[0,1,-1]` therefore has plus2=minus2=stat2=3 and tied=2.

This is the descriptive paired signed-rank statistic. It provides no p-value,
null distribution, significance decision, normal approximation, z score,
continuity correction, confidence interval or effect estimate. Pratt and
zero-split conventions are excluded. It does not treat the two columns as
independent samples, as a Mann-Whitney U calculation would. All-zero and empty
retained populations are rejected explicitly rather than publishing a test.

## Framing, capacity and independent errors

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid,
no CE, CDC or runtime configuration. A frame has at least one accepted beat and
ends at accepted `s_last`. Only `s_keep=1` retains a pair. Masked x/y fields are
ignored while preserving the frame boundary. The first accepted beat supplies
the frame tag even when masked; later tags are ignored. The source holds valid
and every field stable until acceptance or reset.

Capacity counts kept raw pairs, including zeros. RAM is compacted separately:
only nonzero differences in that retained prefix write a `{sign,magnitude}`
word. Thus the raw retained count and replay RAM count can differ. Excess kept
pairs set overflow and drain without changing RAM or any diagnostic count.
A masked excess beat does not cause overflow. Missing tails wait indefinitely.

| Diagnostic output | Meaning over the retained raw-pair prefix |
| --- | --- |
| `m_count` | All retained kept pairs, including x=y |
| `m_nonzero` | Pairs with x!=y; compact RAM population n |
| `m_zeros` | Pairs with x=y; count minus nonzero |
| `m_positive` | Pairs with x>y |
| `m_negative` | Pairs with x<y |
| `m_tag` | First accepted beat's tag |

| `m_errors` bit | Independent rejection condition |
| --- | --- |
| 0 | No nonzero difference in the retained prefix |
| 1 | At least one kept pair exceeded MAX_LEN |

Any error rejects the entire frame: plus2, minus2, stat2 and tied are all zero.
Retained count/nonzero/zero/positive/negative diagnostics, first tag and both
error bits remain meaningful. An all-masked frame has bit0. Filling capacity
with zero pairs and then draining a nonzero pair sets both bits: the excess
pair cannot repair the retained prefix. There is no prefix statistic output.

One frame owns the core until its one result retires. Collection accepts at
II1 while ready. No new frame enters during replay or held output. Every
output field and valid remain stable under arbitrary sink backpressure. The
next frame can accept one period after result transfer. Unbounded source or
consumer stalls prevent a wall-clock completion guarantee.

Reset gates ready and valid low immediately and must span an active edge.
That edge clears scalar state and cancels collection, target/scan reads,
partial rank counts/sums, held result and a blocked next-frame source offer.
RAM and its read register need no reset: a fresh compact prefix is written
before any replay, and zero/overflow rejection never reads an old suffix.
No canceled-frame output is emitted. Output data is meaningful only while valid.

## Parameters, exact widths and architecture

| Parameter | Default | Legal values |
| --- | ---: | --- |
| DATA_W=W | 16 | 1..32, signed two's-complement x/y |
| MAX_LEN=M | 16 | 1..64, including nonpowers of two |
| TAG_W | 8 | 1..32 |

Derived local widths are not user overrides. `CW=COUNT_W=max(1,clog2(M+1))`.
Both raw operands receive explicit sign extension before subtraction into W+1
signed bits. The exact difference is in `[-(2^W-1),2^W-1]`. Its absolute
magnitude fits W unsigned bits, including the signed input extrema. At W=32,
the full-range magnitude is 4,294,967,295; it is not a signed 32-bit value.

For a nonzero target, let L be the number of compact entries with smaller
magnitude and E the number with equal magnitude, including the target itself.
Its doubled average rank is `2*L+E+1`. E>=1 and L+E<=n imply that this value is
in 2..2*n. `RW=CW+1` is sufficient, at most 8 bits. L and E extend unsigned
before the shift/add expression. Each rank enters exactly one sign sum; total
doubled rank mass is n*(n+1). Therefore
`SUM_W=max(1,clog2(M*(M+1)+1))` covers all intermediate/final sums. Defaults
use 9 sum bits, maximum uses **13 bits** for the maximum rank mass **4,160**.
Tied membership and all diagnostics fit CW, at most 7 bits.

Collection stores nonzero `{negative,magnitude}` words in one synchronous RAM.
After error checking, TARGET_READ and TARGET_SETUP load each outer target.
SCAN_READ and SCAN_EVAL replay all n entries, updating L and E with a single
unsigned magnitude comparator. ACCUMULATE adds its doubled rank to the selected
sign sum and increments tied membership when E>1. FINISH selects the smaller
complete sign sum. This nested scan trades quadratic work for a small datapath
without sorted RAM insertion, parallel comparison networks or wide multipliers.

The target read and inner scan share one synchronous read port, consumed only
on following edges. Collection and replay are disjoint; no same-address
read/write mode is assumed. All loop counters are derived-width vectors. No
runtime multiplication/division, vendor primitive, generated table, external
memory or sibling RTL is used. Multiplication in width/storage/bound formulas
is elaboration only.

Logical RAM is `M*(W+1)`: **272 bits** by default and **2,112 bits** at maximum.
This excludes read/target, sum, count, control and output registers. Qualitative
risk is **LOW** at default and **MEDIUM** at maximum because replay latency and
small-RAM mapping depend on the target. LUT/FF/DSP/BRAM counts, Fmax, device fit,
power and RAM primitive inference are unmeasured.

For a valid n-nonzero frame, the exact tail-acceptance E to first-visible-valid
delay is

```text
L(n) = 2 + n*(2*n+3) clock periods
```

Each target takes one read, setup, 2*n scan clocks and accumulation. FINALIZE
and FINISH add two periods. Rejected frames have exact delay 1. Default maximum
is **562 periods**, global maximum **8,386 periods**. First valid can transfer
at the following edge. The TB checks exact delay on every main frame and exactly
n rank accumulations/n*n comparisons on valid main frames. No point/frame per
clock sustained service claim follows from collection's II1.

## Offline use and finite evidence

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s wilcoxon_signed_rank -f files.f
iverilog -g2012 -Wall -tnull -s paired16 -f example/files.f
python -B run_tests.py
```

Both manifests have pure local closures. The fixed example exposes every port
at default parameters. New code is original repository Apache-2.0 work under
root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE).
[SOURCES.md](SOURCES.md) records the actual semantic and pinned-source review.

The independent oracle computes differences with Python integers, sorts them
by magnitude, groups equal magnitudes, and assigns each group the Fraction
average of its occupied ordinal positions. It partitions those ranks by sign.
It does not implement per-target smaller/equal scans, synchronous replay or the
RTL rank formula. Full-width integer output encodings, diagnostics and errors
are compared. Rank-mass and tie-membership conservation are checked separately.

The fixed six `(DATA_W,MAX_LEN,TAG_W)` profiles are `(1,1,1)`, `(2,3,3)`,
`(3,5,8)`, `(8,7,8)`, `(16,16,8)` and `(32,64,32)`. Raw paired signed1 and
signed2 sequences through three pairs are exhaustive. Directed fixtures cover
all-zero/empty data, both full-range subtraction signs, equal magnitudes with
opposite signs, half-integer ranks/statistics, sign reversal and permutation,
multiple tie groups, leading/interleaved zeros, capacity counting zeros,
ignored excess mass, masks/first tags, full-capacity rank sums and maximum
magnitudes. Each profile also has 35 capacity-bounded random and 20 mixed random
frames; an all-zero difference population is correctly rejected.
Source bubbles and real output/pending-next-source stalls exercise full-field
holding.

Twenty additional immediate cancellation targets per profile cover all nine
states; middle/last outer target read/setup; middle/last inner reads/evaluations
at the final target; actual held normal/error results with blocked sources;
overflowing all-zero retained prefixes; and retained-zero partial collection.
Targets reset immediately without another active edge. Each recovery writes
fresh full-range differences and checks an analytic result: a negative singleton
or a positive/negative equal-magnitude tie with exact half-rank sums. Every
fresh result is held, retired and followed by stale-output checks. These 120
reset/recovery pairs are separate from main frame/counter totals. Singleton
boundaries can coincide; the count is of probes, not unique states.

Every compiler/simulator child has a hard 20-second limit. Any timeout is
recorded TIMEOUT/NOT_RUN/INCOMPLETE_TIMEOUT and stops the matrix; rerunning after
that report is refused. No fixture reduction, timeout increase or timeout retry
is allowed. Ordinary concrete non-timeout failures may be fixed and the same
matrix rerun with previous commands/hashes retained. Finite tests do not prove
all data at every legal configuration. No physical evidence is inherited.

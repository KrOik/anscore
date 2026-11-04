# Exact two-histogram Kolmogorov-Smirnov distance

`ks_histogram_distance` receives aligned, signed-key histogram bins with raw
unsigned frequency counts for two populations. It calculates their exact
right-continuous empirical CDF distance in RTL. The caller supplies neither
CDF values nor a precomputed statistic. The result includes the two directional
extrema and an earliest-key witness, using an unreduced integer denominator.

Status is **HW_UNVERIFIED**. Only [verification.json](verification.json)
qualifies the recorded finite lint/unit-simulation checks. Synthesis, PnR, STA,
hardware and expanded regression are not run by this package.

## Numerical contract

Every kept key must be strictly increasing in signed two's-complement order,
including bins whose two frequencies are zero and kept bins beyond capacity.
Each accepted `s_keep=1` beat represents counts `s_a` and `s_b` at `s_key`.
Absent keys have zero mass in both populations. Both histograms must already
share this ordered key stream; there is no sorter or histogram builder.

Retain the first n<=MAX_BINS kept rows and let TA and TB be their respective
frequency totals. For each retained key x, define

```text
FA(x) = sum(a at retained keys <= x) / TA
FB(x) = sum(b at retained keys <= x) / TB
D     = TA * TB
m_plus  = max_x(max(FA(x)-FB(x), 0)) * D
m_minus = max_x(max(FB(x)-FA(x), 0)) * D
m_num   = max(m_plus, m_minus)
m_den   = D
```

The key query is right-continuous: both counts at x enter before its difference
is evaluated. The final CDFs both equal one, so including the last bin is safe.
The four product/statistic fields are unsigned exact integers. No division,
rounding, fraction reduction, floating point, saturation or approximation is
used. A valid result satisfies `0<=m_num<=m_den` and `m_den>0`.

`m_witness_key` and zero-based `m_witness_bin` identify the earliest supplied
kept key achieving the maximum absolute difference. Opposite-sign extrema with
equal magnitudes retain the earlier key. `m_direction` is signed two-bit +1
when FA>FB there, -1 when FA<FB, and zero exactly when the distance is zero.
For zero distance, the witness is the first kept key/bin, even if its two counts
are zero. Leading empty bins therefore remain part of witness indexing.

This is a distance service: it returns no p-value, significance decision,
confidence interval, asymptotic distribution or inferred sample population.
Frequency counts may encode repeated raw observations; they are not normalized
weights. No SciPy location/sign tie compatibility is claimed.

## Framing, errors and reset

One clock, synchronous active-high `rst`, ordinary ready/valid, no CE or CDC.
A frame contains at least one accepted beat and ends at an accepted `s_last`.
Masked rows ignore key and frequencies while preserving frame boundaries.
The first accepted beat supplies `m_tag`, even when masked; later tags are
ignored. The source holds valid and every field until acceptance or reset.

The first MAX_BINS kept rows enter RAM and bounded diagnostic totals. Excess
kept rows set overflow and drain through the tail without changing RAM, bins,
TA or TB. Ordering still compares every kept key, including excess drain.
A masked row cannot cause an ordering error or overflow. `m_bins`,
`m_total_a` and `m_total_b` describe only the retained prefix.

| `m_errors` bit | Independent rejection condition |
| --- | --- |
| 0 | Retained total TA is zero |
| 1 | Retained total TB is zero |
| 2 | A kept key is no greater than the preceding kept key |
| 3 | A kept row exceeds MAX_BINS |

Any error rejects the entire result: numerator, denominator, directional
extrema, witness key/bin and direction are all zero. Bins, bounded totals,
first tag and all error bits remain diagnostic. An all-masked frame has bits0
and 1. Positive mass in excess drain cannot repair a zero retained total. A
zero-frequency duplicate/decreasing key remains an ordering error.

There is one owned frame and one output token. Collection accepts one beat
per cycle while ready; it stops after the tail until the result is retired.
All output fields remain stable under arbitrary sink backpressure. A missing
tail or a permanently stalled sink can hold ownership indefinitely.

Reset gates ready and valid low immediately. Its active edge cancels collection,
read, partial multiplication, held output and a pending next-frame source beat.
Scalar state clears; RAM is unreset. A new frame writes its retained prefix
before replay reads it, so previous words are unreachable. No canceled result
is emitted. Output fields are meaningful only while valid.

## Parameters, widths and architecture

| Parameter | Default | Legal values |
| --- | ---: | --- |
| KEY_W | 16 | 1..32, signed key |
| FREQ_W | 12 | 1..16, unsigned frequency |
| MAX_BINS | 32 | 1..128, including nonpowers of two |
| TAG_W | 8 | 1..32 |

Let M=MAX_BINS, F=FREQ_W and S=M*(2^F-1). Derived local widths are
`COUNT_W=max(1,clog2(M+1))`, `TW=TOTAL_W=max(1,clog2(S+1))`, and `DW=2*TW`.
Local width parameters are not user overrides. Bins are bounded by M, and
totals/prefixes by S. Input frequencies are explicitly extended unsigned to TW
before addition. The largest legal total is 8,388,480, requiring TW=23.

TA*TB and either prefix cross product are at most S^2<2^(2*TW), so DW suffices.
Both unsigned products receive an explicit positive sign bit before subtraction.
The signed contrast is DW+1 bits; its magnitude is at most D and fits DW.
The maximum product/statistic width is **46 bits**, contrast width **47 bits**;
defaults are 34 and 35. Signed minimum and maximum keys are ordinary data.

Collection stores `{key,a,b}` in a synchronous RAM at II1. FINALIZE rejects
errors or starts a shared TW-step unsigned shift/add multiplier for TA*TB.
ROW_READ fetches one RAM word; ROW_EVAL consumes it on the following edge,
updates both prefixes, and starts prefixA*TB. The same engine then calculates
prefixB*TA. Their exact signed difference updates the directional extrema and
updates the absolute witness only on strict improvement. The first row sets
the default zero-distance witness. Replay repeats once per retained row.

Collection and replay are disjoint, so no simultaneous read/write collision
behavior is assumed. There is no runtime multiplication or division operator,
sorting network, external memory, vendor primitive, ROM or sibling dependency.
Multiplication in width, storage and bound expressions is elaboration only.

Logical RAM is `M*(KEY_W+2*FREQ_W)`: **1,280 bits** by default and **8,192 bits**
at maximum. This excludes scalar/read/product/output registers. Risk is
qualitatively **LOW** at default and **MEDIUM** at maximum because mapping of
the small RAM and serialized service latency remain device dependent. Physical
RAM inference, LUT/FF/DSP counts, timing, power and device fit are unmeasured.

Counting clock periods from tail acceptance E to first visible output valid,
the exact schedule for a valid n-bin frame is

```text
L(n,TW) = TW + 2 + n*(2*TW + 4)
```

A rejected frame has exact delay 1. These schedules are checked after the NBA
updates on every main fixture. The default maximum is **1,235 periods**, and
the global maximum is **6,425 periods**. Earliest result transfer occurs on the
next edge after visible valid; next-frame acceptance is one period after result
transfer. Input gaps and sink stalls prevent a wall-clock retirement bound.

## Offline use and finite evidence

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s ks_histogram_distance -f files.f
iverilog -g2012 -Wall -tnull -s distribution32 -f example/files.f
python -B run_tests.py
```

Both manifests have local closures. The example fixes the default parameters
and forwards every port. New work is original repository Apache-2.0 work under
root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE).
[SOURCES.md](SOURCES.md) records actual semantic and pinned-source preflight.

The independent Python oracle first converts each raw count into a Fraction
mass, then independently queries every key against the entire normalized mass
map. It does not reproduce the RTL prefix accumulator or serial product engine.
For total population TA+TB<=32, it also expands raw samples and rank-queries them
with `bisect_right`. Full integer encodings are compared, including the common
denominator, both extrema, witness, sign, errors and all diagnostics.

Six fixed `(KEY_W,FREQ_W,MAX_BINS,TAG_W)` profiles are `(1,1,1,1)`, `(2,2,3,3)`,
`(3,3,5,8)`, `(8,8,7,8)`, `(16,12,32,8)` and `(32,16,128,32)`.
Signed1/F1 sequences through three bins and signed2/F2 sequences through two
bins are exhaustive. Other fixtures cover both signs, zero/one distance,
proportional unequal totals, opposite-sign equal maxima, leading zero bins,
maximum frequencies, full capacity, empty/missing populations, masks/tags,
non-increasing keys including empty/excess rows, bounded-prefix overflow errors,
deterministic random data, source bubbles and real input/output stalls.

The TB checks exact tail delay and expected row/product service counts, CDF
range and final endpoints, output holding and blocked source holding. In each
profile, 18 additional immediate reset targets cover every FSM state, all
multiplier roles in progress and done, middle/last read/evaluate positions,
genuinely held normal/error outputs with a blocked next source, overflowing
collection and zero-frequency ordering failure. Each target is reset before
another active edge, then followed by a fresh analytic recovery result and
stale-output check. These 108 reset/recovery checks are separate from main
frame totals.

Every compiler/simulator child has a hard 20-second timeout. Any timeout records
NOT_RUN/INCOMPLETE_TIMEOUT and stops without retry, fixture shortening or timeout
increase. Concrete non-timeout failures may be corrected and the same fixed
matrix rerun while retaining the previous failure evidence. No finite matrix
constitutes an exhaustive proof over the entire legal parameter/data domain.

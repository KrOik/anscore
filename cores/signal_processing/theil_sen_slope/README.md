# Exact rational Theil-Sen slope

`theil_sen_slope` receives signed integer `(x,y)` observations, constructs all
finite unordered-pair slopes in RTL and returns their exact median. It excludes
pairs with equal x. The result is a signed numerator over a positive unsigned
denominator, with the two central slope endpoints and exact pair populations.
No slope list or sufficient statistic is supplied by the host.

Status after the recorded finite run: **LINT_PASS / UNIT_SIM_PASS /
INTEGRATION_CANDIDATE / HW_UNVERIFIED**. Only `verification.json` qualifies the
checks. No synthesis, PnR, STA, hardware or expanded regression runs here.

## Numerical contract

For retained points i<j with x_i!=x_j, form `(y_j-y_i)/(x_j-x_i)`. Orient each
fraction to a strictly positive denominator by negating both differences when
dx<0. The signed input minima are ordinary data, not sentinels. Every eligible
unordered pair contributes once, including repeated observations' slopes to
other x levels. Equal-x pairs are skipped even if their y values differ; they
do not represent infinities, errors or zero slopes.

Let p be the number of eligible slopes, q=n*(n-1)/2 and z=q-p the equal-x count.
The output `m_pairs=p`, `m_skipped=z`. In ascending exact rational order,

```text
low  = slopes[floor((p-1)/2)]
high = slopes[floor(p/2)]
median = low                    if p is odd
median = (low+high)/2            if p is even
```

`m_low_num/m_low_den` and `m_high_num/m_high_den` are these central endpoints.
`m_even` identifies an even nonzero eligible population. For odd p,
`m_num/m_den` is the central stored fraction, sign/zero extended. For even p,
the exact unreduced output is

```text
m_num = low_num*high_den + high_num*low_den
m_den = 2*low_den*high_den
```

No division, quotient rounding, floating point, saturation, approximation or
fraction reduction occurs. The numerical error is zero over the legal domain.
Equivalent fractions can retain different numerator/denominator encodings,
especially at tied medians; compare their values by exact cross multiplication.
For even p with equal central values, the formula above still applies.

This core returns only the Theil-Sen slope. It supplies no intercept,
confidence interval, distribution approximation, p-value or significance
decision. It does not implement the distinct repeated-median Siegel estimator.
Robustness is the estimator's definition, not a guarantee for arbitrary data
contamination, quantized coordinates or application-specific noise.

## Framing, errors and ownership

One clock, synchronous active-high `rst`, ordinary ready/valid, no CE or CDC.
A frame contains at least one accepted beat and ends at accepted `s_last`.
Only `s_keep=1` contributes a point. Masked x/y fields are ignored, while the
first accepted beat supplies the frame tag even when masked. Later tags are
ignored. The source holds valid and every field until acceptance or reset.

The first MAX_LEN kept observations are retained in arrival order. Kept excess
beats set overflow and drain through the accepted tail without changing RAM,
count or distinct-x diagnostics. A masked excess beat does not set overflow.
Missing tails wait indefinitely. There is one owned frame and one output token;
no new frame can enter before result retirement. All output fields stay stable
under arbitrary consumer backpressure.

| `m_errors` bit | Meaning |
| --- | --- |
| 0 | No finite pair slope in the retained prefix |
| 1 | At least one kept excess observation was accepted |

The flags are independent. Empty, singleton and all-equal-x prefixes have bit0.
For overflow, bit0 refers to the retained bounded prefix: a new x in the drained
tail cannot make it valid. Any error rejects the whole frame: pair populations,
parity, median and both endpoint numerators/denominators are zero. Retained
`m_count`, first tag and error bits remain diagnostic. There is no prefix slope
publication. A horizontal fit with distinct x is valid and has zero numerator
and positive denominator.

Reset gates both ready and valid low immediately. Its active edge cancels
collection, synchronous reads, a partial multiply/insertion, median work, held
output and any pending next input. Scalar control clears; RAM is not reset.
After reset, each sample prefix is collected before pair reads, and each sorted
slope prefix is written before subsequent insertion reads. Old words therefore
cannot enter a future result. No canceled-frame result is emitted. Output fields
have meaning only while valid; there is no external transaction to roll back.

## Parameters, exact widths and architecture

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DATA_W=W` | 12 | 1..16, signed two's-complement x and y |
| `MAX_LEN=M` | 8 | 2..12, including nonpowers of two |
| `TAG_W` | 8 | 1..32 |

COUNT_W=clog2(M+1), P=M*(M-1)/2 and PAIR_W=max(1,clog2(P+1)) are derived local
widths, not overrides. Every count is bounded by M or P. Let S=2^W-1. Signed
differences need D=W+1 bits and have magnitude at most S. Reorientation by -dy
or -dx is exact, including the minimum input to maximum input difference.
The positive denominator and numerator magnitude each fit W bits. A signed
cross product uses 2W+1 bits because its magnitude is at most S^2<2^(2W).
The engine performs exactly W unsigned magnitude shift/add iterations, then
applies the saved sign.

The even median's two signed products are each explicitly sign extended before
addition. Their sum has magnitude <=2*S^2<2^(2W+1), fitting signed NUM_W=2W+2.
Its denominator 2*d1*d2<=2*S^2 fits unsigned DEN_W=2W+1. Odd results fit by
extension. Maximum numerator/denominator widths are **34/33 bits**, default
26/25. There are no hidden host precision or near-equality thresholds.

Collection stores one `{x,y}` word per kept observation at II1. After the tail,
a single synchronous sample read port fetches each unordered pair in three
states. An eligible positive-denominator fraction is inserted into a synchronous
sorted slope RAM. One registered old slope is compared using two sequential
cross products from one shared W-step multiply engine. A strict smaller result
shifts that old word right before reading the next slot. Equal values do not
shift. The current hole is within capacity, and no read/write collision mode is
assumed. Median endpoint reads reuse that port. Three further products from the
same engine form an even median. No runtime multiplier operator, divider,
sorting network, external memory, ROM, vendor primitive or sibling RTL is used.
All multiplication operators in width/capacity expressions are elaboration only.

Logical RAM is `2*W*M + (2*W+1)*P`: **192+700=892 bits** by default and
**384+2178=2562 bits** at maximum. This excludes read, pending-point, multiply,
counter, control and output registers. Risk is qualitatively **LOW** at default,
**MEDIUM** at maximum, because RAM mapping and serialized quadratic insertion
work dominate. RAM primitive inference, LUT/FF/DSP counts, Fmax, power and
device fit are unmeasured. The old untracked fraction comparator is excluded.

For n retained observations, let Q=n*(n-1)/2. A valid pair may compare at most
all previously inserted slopes, so a conservative tail-to-first-valid bound is

```text
B(n,W) = 6*Q + (2*W+5)*Q*(Q-1)/2 + 3*W+8
```

This includes both sample reads, skipped-pair work, every possible synchronous
insertion comparison/shift, median reads and three final products. Its default
maximum is 11,174 periods and global maximum is 79,817. It is an upper bound,
not an exact or data-independent schedule; the TB checks it on every frame.
Rejected frames become valid one period after accepted tail, also checked.
Earliest output transfer is one edge after visible valid. A new frame can
transfer one period after result transfer. Unbounded missing input tails and
output stalls preclude a wall-clock retirement guarantee. No point/frame per
clock sustained service is claimed.

## Offline use and finite evidence

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s theil_sen_slope -f files.f
iverilog -g2012 -Wall -tnull -s robust_slope8 -f example/files.f
python -B run_tests.py
```

The fixed default example forwards every port. Both manifests are complete and
local; run from the package root. New code is original Apache-2.0 repository
work under root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE).
[SOURCES.md](SOURCES.md) records actual semantic/source/license preflight.

The independent oracle groups observations by x, crosses y lists at distinct
x levels, and builds a weighted Fraction slope distribution. Cumulative rank
selection derives both central endpoints without arrival-order pair walking,
insertion positions, RAM shifts or the bit-serial multiplier. An L1 median
subgradient check verifies that at most floor(p/2) slopes lie strictly above
or below the median. The TB compares each rational by full-width exact cross
products, so unreduced encodings need not match reduced Python fractions.
It independently checks p+skipped=n*(n-1)/2 before median reads.

Six profiles W/M/T=1/2/1,2/3/3,3/5/8,8/6/8,12/8/8,16/12/32 cover the full
parameter boundaries. Small signed1 sequences through four points and signed2
sequences through three points are enumerated. Fixtures include zero/one/equal-x
prefixes, both slope signs and zero, positive/negative dx orientation, repeated
points, odd/even central populations, separated/tied medians, close full-width
fractions, guard-bit even sums/denominators, arbitrary arrival permutations,
masks/first tags, exact capacity, overflow and combined errors, deterministic
random points, bubbles and real source/output stalls.

Immediate reset probes cover every reachable controller state, both compare
products, all three averaging products at an actual multiply midpoint and at
product return, a genuinely held normal/error result with a blocked next offer,
and overcapacity collection. Each complete target is followed directly by
`reset_now`, without an intervening active edge. Every cancellation is followed
by a fresh two-point horizontal frame with full-range x difference; it checks
both sample and slope RAM reuse, tag/statistics, retirement and no stale output.
Two-point capacity cannot reach insertion comparisons or averaging, and these
unreachable phases are explicitly excluded. These are finite examples, not
formal reset proofs.

Each local compiler/simulator child is limited to 20 seconds. Six named illegal
parameter configurations must fail elaboration. Positive diagnostics fail;
there are no permitted warnings. The report starts NOT_RUN and is written in
`finally` on failure as well as success, with actual command results, source,
license and vector hashes. Temporary vectors/images auto-clean. All package
text is strict UTF-8/LF. No network, SciPy runtime, physical flow or expanded
regression is needed to reproduce the finite matrix.

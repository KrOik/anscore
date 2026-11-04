# Exact Adjusted Rand agreement of aligned label images

`label_adjusted_rand` compares two aligned segmentation/cluster-label rasters
without requiring the numeric label IDs to correspond. It returns an exact
signed rational Adjusted Rand Index (ARI), the underlying unordered-pair counts,
and an exact partition-equivalence flag. It builds the joint and marginal
populations in RTL and performs all normalization products in RTL. No host
contingency table, precomputed metric, floating-point unit or divider is needed.

This is a global partition comparison: every two kept pixels form a sample
pair, irrespective of spatial adjacency. It differs from intensity SSIM,
descriptor matching, pixel accuracy and the label-region adjacency graph.
Disconnected pixels with the same ID belong to the same category. Label zero
is an ordinary valid category; background exclusion belongs in the shared
`s_keep` mask. Arbitrary relabeling of either raster preserves ARI. Swapping
the rasters preserves ARI and exchanges the two marginal pair counts.

## Exact metric and degenerate cases

For the n kept aligned pairs, define these unordered sample-pair counts:

| Output | Exact count |
|---|---|
| `m_count` | n, the kept pixel-pair population |
| `m_pairs` | P=n*(n-1)/2 |
| `m_same_a` | B, pairs sharing label A |
| `m_same_b` | C, pairs sharing label B |
| `m_same_both` | J, pairs sharing both labels |

For P>0 the expected same-both index is B*C/P, and the maximum index used by
the adjustment is (B+C)/2. The exact result, before a degenerate-case rule, is:

```text
ARI = (J - B*C/P) / ((B+C)/2 - B*C/P)
numerator   = 2*(P*J - B*C)
denominator = P*(B+C) - 2*B*C
```

The returned numerator is signed; the denominator is unsigned and positive
on every error-free output. The unreduced polynomial numerator/denominator
above are returned when that denominator is nonzero. There is no fixed-point
scale, division, quantization, rounding, clipping or reduction to coprime terms.
Negative scores are preserved, for example [0,0,1,1] versus [0,1,0,1] gives
ARI=-1/2. A caller converting this exact fraction owns the later quantization.

`m_degenerate=1` means the polynomial denominator is zero, and the metric is
canonically **1/1**. This includes zero/one kept sample, two all-single-cluster
partitions and two all-singleton partitions. Empty/all-masked input is legal.
For P>0, `denominator=B*(P-C)+C*(P-B)>=0`; it is zero only when B=C=0 or B=C=P,
so this convention describes identical trivial partitions, rather than hiding
an arbitrary division by zero.

`m_equivalent=(B==J && C==J)` reports identical co-membership of every sample
pair, including the empty and singleton cases. It does not require identical
numeric IDs. It is true exactly when the error-free ARI equals one. Raw pair
counts remain their true zero values on degenerate inputs, even though the
reported fraction is 1/1. The score is not a classification significance test
or an assessment of segmentation quality against unprovided ground truth.

## Atomic raster, mask, errors and reset

All signals share rising-edge `clk`. `rst` is synchronous active-high and
there is no CE, CDC or runtime configuration. CE-qualified old image streams
need an explicit adapter. The caller must align A, B, keep, SOF/EOL and tag at
one ordinary `s_valid && s_ready` transfer and hold them stable until acceptance.
No independent alignment buffer is provided for separately arriving images.

Exactly WIDTH*HEIGHT accepted tokens form a row-major raster. `s_sof` is true
only at pixel zero; `s_eol` is true exactly at each last column. There is no
`s_last` input. Masked tokens still advance raster position. The first token's
tag is captured even if masked, and later tags are ignored. A missing token
waits indefinitely; there is no implicit padding, timeout or frame splitting.

`s_a,s_b` are unsigned IDs in 0..LABELS-1. `s_keep=0` removes that aligned
sample from every population and pair count. Illegal numeric IDs on a masked
token are harmless and never address RAM. Marker checking still applies to
masked tokens.

| `m_errors` bit | Meaning |
|---|---|
| 0 | A SOF/EOL marker disagrees with the fixed raster position |
| 1 | Either label of a kept sample is outside 0..LABELS-1 |

Both error bits are independent and sticky. A wrong early/late marker does
not restart capture or change the fixed remaining token count. Once rejected,
tokens drain through the remaining raster with both predicates still checked.
After its final token the entire frame produces one canonical rejection:
numerator, denominator, count, all pair counts and both flags are zero; error
bits and the first token's tag are preserved. No partial metric is published.
If pixel-count alignment is lost, reset is required; marker bits cannot reliably
detect an omitted/duplicated token.

One frame is owned at a time. Input ready is low during table clearing,
the accumulator update clock, product evaluation and held output. A result
transfers on `m_valid && m_ready`; every result field and valid stays stable
while blocked. New-frame input waits for result retirement and fresh clearing.
Payload fields are meaningful only while valid; raw counts are working
accumulators during capture.

Reset suppresses ready/valid immediately while high. An active reset edge
cancels clearing, partial collection, pending count writes, multiplication
and a held result or input offer. Public fields/control clear, but RAM is not
reset. The next complete clear initializes every joint/marginal entry before
it can be read; subsequent reads precede their writes. A canceled raster must
be replayed if still needed. No transaction survives reset.

## Parameters and range proof

| Parameter | Default | Legal values |
|---|---:|---|
| `WIDTH`, `HEIGHT` | 64,64 | Each 1..1024 |
| `LABEL_W` | 4 | 1..8 |
| `LABELS` | 16 | 1..64, at most `2^LABEL_W` |
| `TAG_W` | 8 | 1..32 |

LABELS is the number of legal IDs, including zero. The quadratic table is
bounded explicitly; a wider input bus reports range errors without aliasing.
All settings are static. Illegal parameters deliberately fail elaboration
through `label_adjusted_rand_invalid_parameters__see_README`.

Let N=WIDTH*HEIGHT, Pmax=N*(N-1)/2 and
`T=max(1,ceil(log2(Pmax+1)))`. The static Pmax expression is evaluated at
64-bit width before multiplication, so the maximum geometry does not overflow
an elaboration integer. Derived public widths, which cannot be overridden, are:

```text
COUNT_W = ceil(log2(N+1))
PAIR_W  = T
NUM_W   = 2*T+2  (signed numerator)
DEN_W   = 2*T+1  (unsigned denominator)
```

Every joint/marginal population is at most n<=N and fits COUNT_W. Its old
value before a kept increment is at most N-1, fitting PAIR_W for N>=2; at N=1
that old value is zero. Adding old populations counts new pairs exactly, so
`0<=J<=B,C<=P<=Pmax<2^T` throughout capture. No intermediate population or
pair accumulation wraps.

Three unsigned products use shared factor width `MW=T+1` and complete
`2*MW`-bit results: P*J, B*C and P*(B+C). The first two are below 2^(2T),
the third below 2^(2T+1), and B+C fits MW. Magnitude partial products are
nonnegative and bounded by their full product. Subtraction zero-extends the
products into signed 2T+3 bits and extends once more before doubling. The
true signed numerator has magnitude <2*Pmax^2<2^(2T+1), fitting NUM_W;
the nonnegative denominator is below the same bound and fits DEN_W. Output
slicing discards only proven redundant high bits. Finite tests also check
the intermediate sign extension and denominator top bit.

Default widths are count=13, pair=23, numerator=48 and denominator=47.
At maximum geometry they are 21,39,80,79. There is no sample count capacity
below the static raster size and no saturation mode.

## Architecture, memory ownership and service

One K*K joint RAM and two K-entry marginal RAMs, K=LABELS, store COUNT_W-bit
populations. Each has one synchronous port. Before every raster, the joint
table clears one cell per clock; the first K clocks clear both marginals in
parallel. A kept acceptance reads all three old populations, latches the
two labels and joint address, and the following UPDATE clock writes their
incremented values and adds their old values to J, B and C. P adds the old
total kept count. Reads and writes occupy different clocks; no read-during-write
collision mode is assumed. Source fields may change after acceptance.

Logical RAM storage is `(K*K+2*K)*COUNT_W`: **3744 bits** by default and
**88704 bits** at the maximum. No source-frame RAM, external memory,
coefficient table, vendor primitive or external RTL dependency is required.
Constant-stride shifts/adds form the joint address. One unsigned shift/add
multiplier serially computes all three products; no production runtime `*`
or `/` is used. Static geometry arithmetic is not a datapath multiplier.

A kept, valid input accepted at E allows the next input at E+2. A masked or
already-rejected drain token permits the next edge. Let `Q=K*K` and `MW=T+1`.
Clearing takes Q clocks; after a result transfer, earliest next-frame input
is Q+1 periods later. For each accepted final raster token, valid appears:

| Frame/tail case | Periods after final input |
|---|---:|
| Error-free, kept tail | `3*MW+6` |
| Error-free, masked tail | `3*MW+5` |
| Rejected frame | 1 |

All three product rounds run even for a degenerate metric, giving fixed
error-free tail schedules independent of data. Each round has one setup and
MW multiply clocks. Default kept/masked latencies are 78/77 clocks. Earliest
output transfer is one edge after valid. Source gaps and held output extend
completion; no unconditional wall-clock deadline or video-rate claim is made.

Expected paths are RAM-count increment/pair accumulation, constant address
shift/add, the shared 2MW-bit adder, and final signed product subtraction.
Qualitative resource risk is **LOW** by default and **MEDIUM** at maximum due
to memory mapping and 80-bit arithmetic. Device fit, resource counts, clock
frequency and power are unmeasured. No synthesis, PnR, STA or board test ran.

## Offline example and finite evidence

Both manifests are relative to this package root. `files.f` is the single
local core; `example/files.f` additionally includes `segmentation_agreement`,
a default wrapper exposing all exact fields. The caller supplies aligned
label pairs and mask; the wrapper does not implicitly synchronize two producers.

```text
iverilog -g2012 -Wall -tnull -s label_adjusted_rand -f files.f
iverilog -g2012 -Wall -tnull -s segmentation_agreement -f example/files.f
```

From the repository root:

```text
python -B cores/image_processing/label_adjusted_rand/run_tests.py
```

The runner uses standard-library Python and existing Icarus/vvp, preferring
the local OSS CAD Suite. Every child has a 20-second timeout. Positive
diagnostics fail, and invalid configurations must report the intended marker.
Vectors/binaries use a cleaned task temporary directory. A failed run replaces
any previous PASS report. Nine source/document hashes, vector hashes, root
LICENSE/NOTICE hashes, exact manifest closure and strict UTF8/LF checks are
recorded; there are no sibling RTL dependencies.

The independent oracle groups **sample indices** in Python integer bitsets.
For every index it classifies all later indices as same/different under each
partition and counts intersections. It does not build joint populations or
use bin-square/choose-two formulas or the RTL's old-count increment recurrence.
Exact Fraction expected-index normalization independently verifies the emitted
polynomial fraction. Every raw count, fraction bit, flag, tag, rejection and
tail latency is checked, along with intermediate width invariants.

Eight profiles cover 1x1/K1/L1, 1x7/K3/L2, 7x1/K4/L3, 2x2/K2/L1,
3x3/K3/L2, default 64x64/K16/L4, 1024x1/K64/L8 and 1x1024/K64/L8.
The 2x2 profile exhausts all 256 pairs of binary-label images; 3x3 includes
512 binary partitions against cyclically shifted memberships. Fixtures cover
negative/zero/perfect ARI, relabeling, raster interchange, one cluster versus
splits, all-singleton subsets, empty/singleton masks, included label zero,
masked illegal IDs, seeded random labels, malformed markers and independent/
combined range errors. Maximum 1024x1024 is syntax compiled, not full-frame
simulated. The supported domain is not narrowed to the tested geometries.

Immediate reset probes target all eight controller states, all three serial
product midpoints, rejected-frame drain, and actually held normal/error outputs
with stalled next-raster offers. A pre-tail drain probe is unavailable at 1x1
and explicitly omitted. Each cancellation is followed by a checked singleton
raster that must observe freshly cleared RAM. Real source stalls, post-capture
field changes, source-hold assertions, multi-clock result holds and frame reuse
are required. Twelve illegal configurations are compile-rejected. These are
finite phase probes, not an arbitrary-cycle proof. Service counters include
probe/recovery work; main fixture counts exclude it.

After the recorded suite passes, maturity is **LINT_PASS + UNIT_SIM_PASS**;
the example is **INTEGRATION_CANDIDATE**, all **HW_UNVERIFIED**. Example evidence
is syntax compilation only. No expanded regression or physical tools are run.
Source/license preflight is recorded in [SOURCES.md](SOURCES.md).

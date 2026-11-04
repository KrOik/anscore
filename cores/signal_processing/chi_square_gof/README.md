# Framed Pearson chi-square statistic

`chi_square_gof` receives unsigned integer observed/expected frequency pairs
and computes the Pearson goodness-of-fit statistic for the whole retained
frame. It performs subtraction, squaring, division, accumulation, mass checks
and category counting in RTL. It returns no p-value, threshold or significance
decision. Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE /
HW_UNVERIFIED**; only the finite checks in `verification.json` are qualified.

## Numerical contract

Let `F=FRAC`, and let the retained categories be the first `MAX_BINS` accepted
beats having `s_keep=1`. For each retained category with `E>0`, form

```text
t[i] = RNE((O[i]-E[i])^2 * 2^F / E[i])
q = sum(t[i])
```

RNE means nearest integer with exact ties to even. The output integer
`m_statistic=q` represents `q/2^F`. Every subtraction/square and the final sum
is exact; **each term is rounded before summation**. This is different from
rounding the exact rational total once. For example, F=0, O=[1,3], E=[2,2]
gives 0+0=0, whereas rounding the exact total gives 1.

A retained 0/0 category contributes zero and is excluded from `m_active`.
Any kept O>0/E=0 pair is a domain error, including pairs accepted while
draining excess categories. No division by zero is issued. Successful frames
require equal retained observed/expected totals and at least two active
categories. A single active category is explicitly rejected even when its
statistic would be zero. These are integer frequency counts in the same
units, with no signed or fractional input encoding.

On an error-free frame, with A active categories, the full-domain bound is

```text
abs(m_statistic/2^F - sum((O-E)^2/E)) <= A/(2*2^F)
```

The bound follows from at most half an output LSB per term and exact summation;
it is not a statistical confidence interval. Low precision may produce zero
for a strictly positive ideal statistic. No saturation or wrapping is used.

`m_df=m_active-1` is only an **uncorrected** degrees-of-freedom count for a
common-mass multinomial model with no parameters fitted from these data.
For active<2 it is zero. Estimated parameters need caller-side correction.
The core does not assess independence, expected-frequency adequacy or the
validity of an asymptotic chi-square approximation. `m_df` and the statistic
are usable for that model only when `m_errors==0`.

## Framing, errors and metadata

One rising-edge clock, synchronous active-high `rst`, no CE, CDC or runtime
configuration. Input transfers on `s_valid && s_ready`; all fields must stay
stable until accepted. An accepted `s_last` ends a frame, including a masked
beat. Every frame has at least one accepted beat. The first accepted beat's
tag is returned, even when masked; subsequent tags are ignored.

One result transfers on `m_valid && m_ready`. Every output field remains
stable through arbitrary output stalls. Only one frame is owned at a time;
the next frame waits for result retirement. Reset gates ready/valid low,
cancels input collection, arithmetic, held result and any pending input offer,
and clears accumulated state. A frame missing its tail waits for more input
until reset; there is no timeout or implicit frame splitting.

| Error bit | Meaning |
| --- | --- |
| 0 | Empty: no retained kept categories |
| 1 | Over capacity: a kept category beyond `MAX_BINS` was accepted |
| 2 | Zero expected with positive observed, on any kept beat including excess |
| 3 | Observed and expected **retained-prefix** masses differ |
| 4 | Fewer than two retained categories have positive expected count |

All error bits are independently preserved, with no priority masking. Any
error rejects the complete frame: `m_statistic=0`. Later beats still drain
through the accepted tail. Once a domain/capacity error is known, unnecessary
arithmetic stops, while bounded metadata accumulation continues.

`m_count` counts retained kept categories, including 0/0; `m_active` counts
retained positive-E categories. `m_sum_observed` and `m_sum_expected` are exact
retained-prefix masses. These metadata, `m_df` and `m_tag` remain diagnostic
on rejected frames; their presence does not validate a partial statistic.
On overcapacity, no claim about the complete unbounded tail's mass is made:
error bit 3 describes the bounded retained prefix. Masked beats do not count,
alter masses, cause capacity/domain errors or contribute terms.

## Parameters, widths and architecture

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DATA_W=W` | 16 | 1..24 |
| `MAX_BINS=M` | 16 | 1..256, including nonpowers of two |
| `FRAC=F` | 16 | 0..24 |
| `TAG_W` | 8 | 1..32 |

Derived local widths cannot be overridden:
`L=ceil(log2(M))` (zero for M=1), `COUNT_W=max(1,clog2(M+1))`,
`MASS_W=W+L`, `STAT_W=2W+F+L`. Illegal public parameters fail elaboration
through a named `chi_square_gof_invalid_parameters` unresolved instance.

For B=2^W-1, absolute difference is at most B and its full unsigned square
is at most B^2. With E>=1, each rounded term is at most the integer
B^2*2^F, strictly below 2^(2W+F). Summing at most M terms therefore fits
`STAT_W`; each mass is at most M*B < 2^(W+L). Count and active range from
zero through M, and df is at most M-1. The sign bit of each reused signed
division operand/result is explicitly positive. Its numerator width is
2W+1, denominator W+1, result 2W+F+1 and iteration count N=2W+1+F<=73.
Thus the old divider's static limits are respected for every legal profile.
Default mass/statistic widths are 20/52; maximum widths are 32/80.

One W-by-W square multiplier feeds a separate product register. One unchanged
`fp_div_iter` from `../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv`
is shared across all categories. It performs nearest-even quotient rounding;
no new divider, RAM, ROM, table generator or vendor primitive is introduced.
Difference and product are registered before division; term accumulation is
after the divider result. The package includes its complete dependency closure
in both manifests. Root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE) apply; preflight/provenance are in
[SOURCES.md](SOURCES.md). No external code was copied or redistributed.

Let N=2W+1+F. A kept positive-E category needing arithmetic has input II=N+4;
masked, 0/0 or already-rejected drain beats can transfer on consecutive edges.
A tail needing arithmetic presents the result N+4 periods after its accepting
edge; other tails take one period. At defaults N=49, these are 53 periods.
The next frame can be accepted one period after the prior result transfers.
The finite TB checks both tail schedules for every frame. Unlimited input
bubbles/output stalls imply no unconditional wall-clock completion bound.

There are no logical storage arrays. Default qualitative resource risk is
**LOW**, rising to **MEDIUM** at maximum from the 24-bit square, up to 73-bit
quotient recurrence and 80-bit accumulation. No measured LUT/DSP/RAM count,
frequency, power or device-fit claim is made. No synthesis, PnR, STA, board
test or expanded regression has run.

## Offline use and finite evidence

From this directory:

```text
iverilog -g2012 -Wall -tnull -s chi_square_gof -f files.f
iverilog -g2012 -Wall -tnull -s category_fit16 -f example/files.f
python -B run_tests.py
```

The example maps up to 16 unsigned16 category pairs to a Q16 statistic,
with the same error/metadata protocol. It is an integration candidate, not a
qualified statistical application. No network access is needed after checkout.

The bounded runner prefers local OSS CAD Suite Icarus/vvp and allows
IVERILOG/VVP overrides. Every subprocess has a 15-second timeout; temporary
vectors and simulator images are automatically removed. Only the existing
divider's known missing-timescale warnings are permitted; other positive
diagnostics fail. Verification records tool outputs, all source/dependency
SHA256 values and vector hashes.

Six profiles cover W=1,2,4,8,16,24; M=1,4,8,7,16,256; F=0,8,16,24;
TAG_W=1,3,8,32, including the maximum configuration. Exact Python Fraction
terms and Python's nearest-even rational round form an independent oracle,
and each valid frame also checks the rational total-error bound. Tests cover
all length-one through three observed/expected combinations at W=1 and W=2,
positive/negative differences, zero terms, zero/zero skips, count/mass maxima,
rounding ties in both directions, mass-preserving transfers, simultaneous
errors, error predicates in excess categories, masked tails/first tags,
source bubbles/stalls and held complete outputs. Eight invalid parameter
configurations must fail with the intended named instance.

Each profile immediately asserts `reset_now` at eight observed boundaries:
partial collection, pending multiplication, divider launch, in-flight middle
division, finalization, held result with a pending next-frame offer, domain
drain and capacity drain. No active edge intervenes between observation and
reset assertion. Each cancellation is followed by an independently checked
fresh empty frame. These finite probes are not exhaustive reset proofs.

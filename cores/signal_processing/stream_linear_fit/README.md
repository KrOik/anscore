# Framed integer linear regression

`stream_linear_fit` receives signed integer `(x,y)` pairs and fits
`y = slope*x + intercept` by ordinary least squares. Masking, frame collection,
exact statistics, solving, quantization and result framing occur in RTL; the
caller does not calculate coefficients or sufficient statistics. The existing
`linear_solve2x2` is instantiated without modifications. This adds a streaming
sample-to-fit capability to its arbitrary-equation command interface.

## Numerical and capacity contract

All samples are signed `DATA_W`-bit two's-complement integers, including the
minimum negative value. Retain the first `2^COUNT_W-1` accepted pairs having
`s_keep=1`. Additional kept pairs set sticky frame status `m_overflow=1` and
are drained through the accepted frame tail without contributing. Masked beats
consume framing and tag information but do not change count or statistics.
`m_count` reports retained pairs, not total beats. Overflow results describe
that bounded prefix; they are not an estimate of all kept pairs.

For the retained pairs, the exact integer normal equations are:

```text
[ sum(x*x)  sum(x) ] [ slope     ] = [ sum(x*y) ]
[ sum(x)    n      ] [ intercept ]   [ sum(y)   ]

spread = n*sum(x*x) - sum(x)*sum(x)
```

The dependency computes exact determinants and numerators, and divides only
at final output quantization. The returned integers represent real values
`m_slope/2^FRAC` and `m_intercept/2^FRAC`. Quantization truncates toward zero;
each in-range coefficient has an error strictly less than one output LSB.
Each coefficient outside the signed `RESULT_W` range saturates independently:
`m_saturated[0]` is slope and `[1]` is intercept. An exactly representable
minimum negative value is not saturation. No small-error guarantee applies to
saturated coefficients. `FRAC>RESULT_W-1` is legal and gives a smaller real
range, so ordinary coefficients may saturate.

`m_spread` is the exact nonnegative integer above, zero-extended to
`2*STAT_W+1` bits, with `STAT_W=2*DATA_W+COUNT_W+1`. It also equals
`sum(i<j, (x[i]-x[j])^2)`. If it is zero, `m_degenerate=1`, both coefficients
and saturation flags are zero. This includes zero retained pairs, a singleton
and any constant-x prefix. There is no unique slope/intercept in these cases.
Constant y with nonconstant x is a valid horizontal fit. No near-zero-variance
threshold is applied; exact positive integer spread is solved normally.

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DATA_W` | 8 | 2..10 |
| `COUNT_W` | 6 | 1..12 |
| `FRAC` | 16 | 0..24 |
| `RESULT_W` | 32 | 2..64 |
| `TAG_W` | 8 | 1..32 |

The coupled constraint **`2*DATA_W+COUNT_W+1 <= 24`** also applies, matching
the frozen solver's input-width limit. Defaults retain at most 63 signed8
pairs. Signed10 supports at most seven pairs (`COUNT_W<=3`); signed2 with
`COUNT_W=12` retains 4095. `COUNT_W=1` is legal but its capacity of one means
every result is degenerate. Invalid parameters/combinations fail elaboration
through an unresolved `stream_linear_fit_invalid_parameter__see_README`
instance. There are no runtime configuration registers or configuration races.

## Transfers, reset and framing

- One rising-edge clock, synchronous active-high `rst`, no CE or CDC. Ordinary
  `s_valid && s_ready` accepts all input fields together. The producer holds
  them stable until acceptance. Reset gates `s_ready` and `m_valid` low and
  cancels partial frames, arithmetic, queued results and a blocked input offer.
- A frame has at least one accepted beat and ends on its accepted `s_last=1`.
  There is no separate start command. The first accepted beat supplies the
  result tag even if masked. Subsequent tags are ignored. An all-masked frame
  returns a zero-count degenerate result. Missing `s_last` leaves the current
  frame open indefinitely; there is no forced termination or timeout.
- The core accepts no new frame during solving or a held result. It resumes
  admission on the cycle after result transfer. There is one frame in flight,
  preserving order. `m_slope`, `m_intercept`, `m_count`, `m_degenerate`,
  `m_overflow`, `m_saturated`, `m_spread` and `m_tag` remain stable while
  `m_valid && !m_ready`. Output fields are unspecified when valid is low.
- Reset across a rising edge clears count/statistics/tag/status and resets
  the solver. Pair scratch registers are initialized by an accepted retained
  pair before use. Input/output transactions canceled by reset must be replayed
  by the caller if still needed. No external memory or bus errors are involved.

## Architecture, service and structural risks

The collector stores four signed `STAT_W`-bit sums and a count, rather than
the sample frame. One signed `DATA_W` by `DATA_W` source-level multiplier is
selected between `x*x` and `x*y` on successive processing clocks. A retained
pair accepted at edge E updates its square at E+1 and its cross/linear sums
and count at E+2; another beat can be accepted at E+3. Masked or excess pairs
require no product clocks and permit next-edge acceptance. These are maximal
source service rates with continuously valid input, not measured clock rates.

Since `n<2^COUNT_W`, each linear sum has magnitude at most
`n*2^(DATA_W-1)`, and each product-sum magnitude is at most
`n*2^(2*DATA_W-2)`. Signed `STAT_W` therefore retains all sums with guard
bits. Full signed `2*DATA_W` products are sign-extended before accumulation;
in particular, squared minimum-negative samples remain positive. The count
is zero-extended before entering the solver. No intermediate sums wrap,
saturate, discard fractional bits or divide by rounded means.

Let `A=STAT_W`, `B=2*A+1+FRAC`. From the solver command edge, valid-result
latency is `L=6*(A+1)+2*(B+1)` for nondegenerate frames or `L=2*(A+1)` for
degenerate frames. From the accepted tail edge, valid appears after `L+3`
periods if the tail is retained, or `L+1` if masked/excess. Earliest output
transfer is one edge later. Defaults have nondegenerate `L=272`; a retained
tail therefore has 275-period valid latency. The sink may stall indefinitely;
there is no unconditional finite completion guarantee under backpressure.

The dependency shares iterative shift/add multiplication and restoring
division; it adds no hardware `*` or `/`. The collector's multiplier is small
but actual DSP/LUT mapping is unknown. The expected paths are the selected
sample multiplier plus statistics adder, and the solver's wide add or
compare/subtract. There are no arrays, BRAMs, ROMs, vendor primitives, clock
crossings or external storage. Storage grows linearly with widths, not frame
length. Qualitative resource risk is **LOW** at defaults and **MEDIUM** at
the widest coefficient/fraction/result profile. This is a structural judgment;
device fit, LUT/FF/DSP counts, Fmax, timing, power and hardware behavior are
unmeasured. Historical physical results of other modules do not qualify this
composition.

## Offline use and finite evidence

From this package directory, `files.f` compiles the production core and its
single committed sibling dependency. `example/files.f` additionally includes
`example/fit8_example.sv`; both manifests use paths relative to the **package
root**, not to the manifest file. The example exposes all coefficient/error,
count and tag signals and discards only exact spread. Its paired data ports
are ordinary signed samples; no physical converter interface is implied.
No includes, tables, downloads or generated production files are required.

```text
iverilog -g2012 -Wall -tnull -s stream_linear_fit -f files.f
iverilog -g2012 -Wall -tnull -s fit8_example -f example/files.f
python -B cores/signal_processing/stream_linear_fit/run_tests.py
```

The Python command runs from the repository root. It prefers the local OSS
CAD Suite and gives every subprocess a 15-second timeout. Deterministic
`vectors.svh` and simulator files are generated in a task-specific temporary
directory and removed on exit. The persistent TB and vector generator are
included. The runner rejects non-LF files; `.gitattributes` preserves LF.
`verification.json` binds the finite checks to every package source/document
and the unchanged solver dependency using SHA256.

The independent oracle centers each sample with exact Python `Fraction`
means, computes centered covariance/variance, and checks both stationarity
conditions before quantization. It does not form Cramer's numerators or mirror
the product/divider schedule. Six profiles cover minimum data/tag/fraction,
maximum data/statistics/fraction/result/count/tag widths, and the capacity-one
case. The smallest profile enumerates all 256 ordered two-pair frames. Other
cases cover minimum negative samples, positive/negative slopes, horizontal
fits, constant x, zero/all-masked frames, singleton, masks at boundaries,
exact-capacity and over-capacity prefixes, truncation/saturation and seeded
noisy data. Tests compare every output field, exact tail latency, capture of
input/tag fields, source stalls, held-output stability, replay without reset
and reset during collection, both product phases, solver offer, multiplication,
division where reachable, and pending output. Eleven invalid parameter cases
are rejected; the default example is syntax compiled.

Evidence maturity is **LINT_PASS + UNIT_SIM_PASS**, with the example an
**INTEGRATION_CANDIDATE** and all new/composed RTL **HW_UNVERIFIED** once the
recorded runner completes successfully. Finite cases are not exhaustive
verification over all frames or parameter combinations. No synthesis, PnR,
STA, board work or expanded regression is part of this package's evidence.

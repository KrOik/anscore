# Uniform gradient-block Shi-Tomasi corner score

`block_shi_tomasi` collects a finite block of signed gradient pairs and returns
the minimum and maximum eigenvalues of its exact integer structure tensor.
It composes the committed `symmetric_eigen2x2` solver and its existing
`fp_sqrt_iter` dependency; gradients, statistics and eigenvalues are computed
in RTL. A strict threshold decision, retained count, energy, exact isotropy
flag and tag accompany each block result.

This is a **uniform block sum**. The caller supplies gradients and block
boundaries. There is no source-image derivative generator, Gaussian weighting,
sliding raster window or nonmaximum suppression. The score grows with the
number of retained samples; it is not divided by count. This is not API or
bitwise compatibility with scikit-image's Gaussian-window corner response.

## Numerical contract and status

Each accepted token has signed two's-complement integer `s_gx,s_gy`. Tokens
with `s_keep=1` contribute, in input order, to:

```text
xx = sum(gx*gx)       xy = sum(gx*gy)       yy = sum(gy*gy)
M = [xx xy; xy yy]    Q = 2^FRAC
raw_min = floor(Q * minimum_eigenvalue(M))
raw_max = floor(Q * maximum_eigenvalue(M))
```

The reported signed `m_score,m_max_score` are those exact floor codes followed
by independent signed SCORE_W-bit saturation. Dividing a nonsaturated result
by Q gives error in `[0,1/Q)`, measured as true eigenvalue minus returned value.
No intermediate gradient product or tensor sum is rounded or clipped. Each
outer product is positive semidefinite, so both eigenvalues are nonnegative.
Only positive output saturation is reachable for valid blocks.

| Result field | Meaning for status OK |
|---|---|
| `m_score`, `m_max_score` | Ascending floor-quantized, saturated eigenvalues |
| `m_saturated[0]`, `[1]` | Minimum / maximum raw score exceeds the signed output maximum |
| `m_corner` | Strict `raw_min > captured_threshold`, before output saturation |
| `m_isotropic` | Exact repeated eigenvalues: `xx==yy && xy==0` |
| `m_count` | Number of retained gradients |
| `m_energy` | Exact unsigned trace `xx+yy`, without Q scaling |
| `m_tag` | First accepted token's tag |

`s_threshold` is an unsigned SCORE_W-1-bit **score code**, in the same Q scale
as the raw score. Its legal range is zero through the signed output maximum.
Equality does not mark a corner. If the minimum clips, its true raw value is
strictly above every legal threshold, including the maximum threshold. The
decision remains true even though the reported score equals that threshold.
This floor-code comparison can differ within one LSB from comparing the
unquantized eigenvalue to `threshold/Q`; that real-valued comparison is not
implemented.
Isotropy uses the original tensor, so equal quantized or clipped score codes
do not imply isotropy. A nonempty all-zero block returns score/energy zero,
isotropic=1 and corner=0.

| `m_status` | Block interpretation and payload |
|---|---|
| 0: OK | Between one and MAX_SAMPLES retained tokens, as specified above |
| 1: EMPTY | No retained token; scores, flags, count and energy are all zero |
| 2: OVERFLOW | More than MAX_SAMPLES retained tokens; the entire block is rejected with the same zero payload |
| 3 | Reserved, never generated |

All statuses return the first token's tag. Overflow drains tokens through the
accepted `s_last`; no prefix score, count or energy is published. Masked tokens
do not consume capacity, including masked first and final tokens. No missing
tail timeout is provided: the producer must eventually supply `s_last`.

## Parameters and exact ranges

| Parameter | Default | Legal values |
|---|---:|---|
| `GRAD_W` | 9 | 2..11 |
| `MAX_SAMPLES` | 64 | 1..1024, subject to the coupled bound below |
| `FRAC` | 8 | 0..24 |
| `SCORE_W` | 32 | 2..64 |
| `TAG_W` | 8 | 1..32 |

Let `C=ceil(log2(MAX_SAMPLES))`, with C=0 at capacity one. The coupled bound
is **`STAT_W=2*GRAD_W+C <= 24`**, matching the frozen eigen solver's input
domain. Signed9 gradients permit up to 64 samples, signed10 up to 16 and
signed11 up to four. Signed2 supports capacity 1024. The defaults cover an
8x8 gradient tile, including the full central-difference range of unsigned
8-bit pixels. They do not generate those differences internally.

Full signed products have 2*GRAD_W bits, including the positive square of
the minimum-negative gradient. For `G=GRAD_W`, each tensor entry has magnitude
at most `MAX_SAMPLES*2^(2G-2) <= 2^(STAT_W-2)`. Signed STAT_W sums retain the
whole supported range. `m_energy` has STAT_W+1 bits and fits the nonnegative
trace. `m_count` has `ceil(log2(MAX_SAMPLES+1))` bits. These bounds cover every
legal input block, including maximum capacity and signed extrema.

All parameters are static. Illegal configurations deliberately fail
elaboration through unresolved
`block_shi_tomasi_invalid_parameter__see_README`. `FRAC>SCORE_W-1` remains
legal and can clip ordinary scores. There is no runtime width configuration.

## Clock, capture, backpressure and reset

All ports share rising-edge `clk`. `rst` is synchronous high: hold it across
a rising edge to cancel partial collection, arithmetic or a held result.
Ready/valid are suppressed while reset is high. Reset clears all public result
fields and resets the composed eigen and sqrt controllers. A canceled block
must be replayed by its caller. There is no CE, CDC, memory bus or bus-error
protocol; CE-qualified neighbors require an explicit adapter.

Ordinary `s_valid && s_ready` accepts a gradient token, its keep/last fields,
threshold and tag. The producer holds all these fields stable until acceptance.
The first accepted token atomically captures threshold and tag, even if masked;
later tokens' threshold/tag are ignored. `s_last` closes the block even when
masked. Internal work advances independently of input valid and output ready.

One block is in flight. The source may encounter stalls between retained
tokens, and ready stays low during finalization, eigen solving and held output.
All output fields and valid remain stable while `m_valid && !m_ready`.
`m_valid && m_ready` consumes the result, and the next token can transfer on
the following rising edge. Output fields are unspecified when valid is low.
No cross-block overlap or FIFO is implied.

A retained token accepted at E uses one shared G-by-G multiplier expression
over three clocks: xx at E+1, yy at E+2, xy/count at E+3. The next token can
transfer at E+4. Masked or excess tokens take no arithmetic clocks and can be
accepted on consecutive edges. The eigen solver uses its existing iterative
shift/add squares and iterative root. With `N=STAT_W+FRAC+1` and
`L=4*N+6`, result valid appears after the accepted final-token edge by:

| Final block case | Periods until valid |
|---|---:|
| OK, retained final token | L+6 |
| OK, masked final token | L+3 |
| EMPTY or OVERFLOW | 1 |

Default N=33 gives 144/141 periods for the two OK cases. Earliest output
transfer is one edge after valid. Upstream gaps and downstream stalls extend
block completion; there is no unconditional wall-clock deadline. These are
controller schedules, not measured hardware frequency or pixel-rate claims.

## Architecture, dependencies and example

One small signed gradient multiplier is time-shared across the three tensor
updates. No block/frame sample RAM, register arrays, divider, coefficient ROM,
external storage or vendor primitive is required. The old eigen solver shares
one shift/add multiplier across its squares and reuses `fp_sqrt_iter`; only
that iterative sqrt module is instantiated from the dependency file. The
unused `fp_sqrt_pipe` definition is not a parallel stage of this datapath.

This composition trades sustained token rate for small state and arithmetic
reuse. A parallel tensor accumulator plus replicated/pipelined eigen arithmetic
could serve higher rates, but no one-token-per-clock requirement was given.
Expected paths include the gradient product plus tensor add, the eigen
multiplier feedback add, sqrt compare/subtract and final clamp. Registers grow
with tensor/fraction/result widths, not sample storage capacity. Qualitative
resource risk is **LOW** by default and **MEDIUM** at maximum widths. LUT/FF/DSP
mapping, device fit, Fmax, timing and power are unmeasured. Historical checks
of a dependency do not qualify this new composition.

Both manifests are interpreted relative to this package root and include the
unchanged tracked dependencies:

```text
../../signal_processing/dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv
../../signal_processing/symmetric_eigen2x2/rtl/symmetric_eigen2x2.sv
```

`example/gradient_tile_score.sv` instantiates defaults and exposes every result
field. It is an offline gradient-block wrapper, without a connected raster
source. The production and example closures can be syntax checked here with:

```text
iverilog -g2012 -Wall -tnull -s block_shi_tomasi -f files.f
iverilog -g2012 -Wall -tnull -s gradient_tile_score -f example/files.f
```

## Finite verification and maturity

From the repository root run:

```text
python -B cores/image_processing/block_shi_tomasi/run_tests.py
```

The runner uses only Python's standard library and existing Icarus/vvp,
preferring the local OSS CAD Suite. Every compile/simulation subprocess has a
20-second timeout. Deterministic generated vectors and executables live in an
automatically cleaned task temporary directory. Nine package source/document
hashes and the two dependency hashes are recorded in `verification.json`.
Both dependency hashes must match the baseline's committed Git blobs, and
both manifests must have the exact intended source closure. Observed source
stall and held-result cycles are recorded. All local files use LF;
`.gitattributes` preserves those bytes.

The independent oracle first forms integer outer-product sums, then obtains
each exact fixed-point floor by integer matrix-inertia bisection: `Q*M-z*I`
is PSD iff both diagonals and determinant are nonnegative; it is negative
definite iff the first diagonal is negative and determinant positive. Adjacent
integer bounds are checked. No discriminant, square root or RTL root correction
is evaluated by the oracle. Corner decisions use the unclipped result.

Seven actual profiles cover G/capacity/FRAC/SCORE_W/TAG_W:
`2/1/0/3/1`, `2/4/0/2/1`, `3/5/4/8/3`, `9/64/8/32/8`,
`11/4/24/64/32`, `2/1024/0/16/8`, and `8/16/24/8/8`.
The signed2/capacity4 profile exhausts all 256 ordered pairs over the full
signed2 gradient plane. Fixtures include empty and zero blocks, signed extrema,
collinear/orthogonal/isotropic/anisotropic tensors, capacity and overflow,
masked first/final tokens, changing later threshold/tag, zero/maximum/random
thresholds, clipping and seeded random blocks. Every output field and exact
tail latency is checked. Inputs are disturbed after acceptance. Real source
stalls, multi-clock held outputs and replay without reset are required.

Twelve immediate reset phase probes per profile cover the eight parent states,
the old eigen multiply, old sqrt run/available result and eigen available result.
`reset_now` asserts immediately after observing each phase, with no extra active
edge. The held-output probe also cancels a pre-offered next block. These are
finite phase checks, not arbitrary-cycle proof. Eleven illegal parameter
configurations must be compile-rejected. Known Icarus missing-timescale warnings
from unchanged sqrt modules are retained in the report; other successful-check
diagnostics fail the runner.

After the recorded suite passes, maturity is **LINT_PASS + UNIT_SIM_PASS**;
the example/composition is **INTEGRATION_CANDIDATE**, all **HW_UNVERIFIED**.
The example has syntax-only evidence. No synthesis, PnR, STA, hardware or
expanded regression has run. Finite tests do not prove every legal width or
all possible longer blocks.

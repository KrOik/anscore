# Hardware three-point affine RANSAC

`affine_ransac.sv` estimates a six-parameter affine mapping from matched integer
point coordinates. It generates seeded three-point hypotheses, solves them in
hardware, scores every stored match and returns the best consensus model.
There is no host-generated matrix, silent identity fallback or inlier-refinement
step. The fixed-budget **three-point / quantized / L1-residual** variant is
explicitly defined below; it is not bit-compatible with OpenCV's estimator.

## Input and output contract

Inputs s_x,s_y and s_u,s_v are **signed 16-bit integer coordinates** in
[-32768,32767]. The forward model maps source to target:

```
uQ = a00*x + a01*y + a02
vQ = a10*x + a11*y + a12
```

All six output coefficients are signed40-bit integers with FRAC fractional
bits. FRAC=0..16, default8. For example identity has a00=a11=1<<FRAC, other
coefficients zero; translation10 means a02=10<<FRAC. Output numeric range is
[-2^(39-FRAC), 2^(39-FRAC)-2^-FRAC]. Source/target coordinates remain integers.
No perspective terms, descriptor matching, image warp or inverse is included.

CAPACITY is32 or64. On the first accepted point, snapshot:

- cfg_count[6:0]: 3..CAPACITY matches in this transaction.
- cfg_iterations[15:0]: 1..65535 hypotheses, including degenerate/range rejects.
- cfg_seed[31:0]: deterministic xorshift32 state; zero is mapped to1.
- cfg_threshold[31:0]: inclusive **QFRAC L1 reprojection residual** threshold.

For example with FRAC8, threshold512 means a sum of absolute x/y errors <=2
pixels. It is not an L2 radius or squared threshold. Later live config changes
have no effect. s_first must be true exactly on the first match; s_last exactly
on match cfg_count-1. No tags are carried through this numerical estimator;
integrators associate the single result with the enclosing match transaction.

All handshakes require rst_n && ce && valid && ready. Reset is synchronous
active low, overrides CE, and aborts partial capture, all arithmetic and held
output. Do not count transfers while reset is asserted even if combinational
ready is high. Source gaps and CE pauses are supported. Once all matches are
captured, s_ready is low until the result is accepted. The point memory has a
true synchronous read port. Different transactions do not overlap.

m_valid qualifies an output record, model_valid qualifies its matrix.
best_count is consensus size; best_residual is the sum of residuals **only over
inliers**. Output coefficients, count, score, validity and error all remain
stable under m_ready backpressure and CE pauses. On result handshake done
pulses for one enabled cycle, busy clears and capture is available again. CE=0
holds a pulse, so consume done with CE qualification.

## Fully specified hypothesis and score algorithm

Each hypothesis draws exactly three distinct indices in a bounded sequence,
with no retry loops. Before each draw, let r be the current state and advance
it by xorshift32 (shifts13,17,5) afterward:

```
i0 = (r.low16) % count
i1 = (i0 + 1 + next_r.low16 % (count-1)) % count
t  = next_next_r.low16 % (count-2)
lo,hi = sorted(i0,i1)
if t>=lo: t+=1
if t>=hi: t+=1
i2 = t
```

This deterministic reduced-modulo sampling is biased when counts do not divide
65536. It is not claimed to be a uniform RANSAC sampler. It does supply distinct
indices, deterministic seed replay and a fixed number of draws per hypothesis.

For matches0,1,2, subtract match0 from the other two. Let
det=dx1*dy2-dx2*dy1. Reject if det=0 or if the corresponding target triangle
du1*dv2-du2*dv1=0. Thus exact collinear/duplicate source or target triangles are
rejected. Near-collinear triangles are not automatically rejected; large or
poorly conditioned models must compete by consensus/range checks.

```
a00 = trunc_toward_zero(((du1*dy2-du2*dy1)<<FRAC)/det)
a01 = trunc_toward_zero(((dx1*du2-dx2*du1)<<FRAC)/det)
a10 = trunc_toward_zero(((dv1*dy2-dv2*dy1)<<FRAC)/det)
a11 = trunc_toward_zero(((dx1*dv2-dx2*dv1)<<FRAC)/det)
a02 = (u0<<FRAC) - a00*x0 - a01*y0
a12 = (v0<<FRAC) - a10*x0 - a11*y0
```

Reject the hypothesis if any coefficient or translation exceeds signed40.
Quantization occurs in each linear coefficient **before** the anchored
translation is formed. Scoring uses this actual quantized matrix, not an ideal
float model. No inverse or post-quantization nonsingularity guarantee is made;
very coarse FRAC can collapse a nonsingular continuous mapping.

For every point, residual=abs(uQ-(u<<FRAC))+abs(vQ-(v<<FRAC)). A residual <=
threshold is an inlier. A candidate requires >=3 inliers. Best model ordering:
larger inlier count; then smaller inlier residual sum; then earliest hypothesis
on an exact tie. There is no inlier least-squares refit. All configured
hypotheses run; no adaptive early termination/confidence formula is used.

## Errors and limitations

| error_code | Meaning |
|---|---|
| 0 | Valid model returned |
| 1 | Invalid runtime count, over-capacity count or zero iteration budget |
| 2 | First/last marker mismatch |
| 3 | All hypotheses rejected or no candidate with >=3 inliers |
| 4 | Defensive illegal-state recovery |

Errors produce a held result record and require normal m_ready acknowledgement,
not a reset. Config/marker errors and a normal no-model result return zero
coefficients, count0, score0, model_valid0; they do not pretend to be identity.
A fresh legal first point clears the error. No transaction timeout is applied
while awaiting missing input points: the source must complete or reset it.

Accuracy depends on the iteration budget, sample distribution, threshold,
coordinate spread and fixed precision. Exact triangle rejection is not a
condition-number test. Without refinement, this is deliberately narrower than
a production registration stack. It handles negative/4K-sized coordinates and
arbitrary affine rotation/shear/scale/translation within its range, but does
not guarantee a correct model for arbitrary outlier fractions.

## Widths, latency and resources

Input differences are signed17-bit (magnitude<=65535). Cross products and their
differences have magnitude <2^33; after FRAC<=16 scaling, Cramer numerators stay
below2^49, safely inside signed64. Signed40 coefficients multiplied by signed16
coordinates fit signed56, and two such terms plus translation and target QFRAC
fit signed58. Absolute L1 residual is below2^59. Inlier residuals are bounded by
the unsigned32 threshold, so a sum of at most64 inliers is below2^38. The 64-bit
score cannot overflow. Range checks precede narrowing to signed40.

A single shared shift/add multiplier consumes17 enabled cycles for any signed
64-by17 operation. A single unsigned64 restoring divider consumes64 cycles per
coefficient with explicit sign restoration. No general combinational multiplier
is needed. The draw uses a shared low16 modulo count expression. Stored points
consume CAPACITY*64 bits. Candidate/arithmetic state and best matrix are separate
so best output survives later rejected hypotheses.

Input II1 while capturing. Hypothesis latency is deterministic for a given
sample/data path, and bounded independently of software: at most
`582+77*count` enabled edges per fully scored hypothesis, plus final result
presentation. Degenerate or range-rejected hypotheses use fewer cycles. All
configured hypotheses count toward the same budget. No pixel-rate or real-time
claim is made. CE and output stalls extend wall-clock time.

Isolated `synth_gowin -noalu -nodsp` reports CHECK zero problems:

| Capacity / FRAC | LUT1..4 | FF | MUX5 | MUX6 | RAM | DSP |
|---|---:|---:|---:|---:|---|---:|
| 32 / 8 | 5721 | 2006 | 678 | 16 | 32 RAM16SDP4 | 0 |
| 64 / 16 | 5472 | 1912 | 632 | 11 | 2 SDPX9B | 0 |

Both measured isolated configurations fit the requested15K LUT/4DSP bounds.
These include top-level I/O buffers; they are not routed or integrated metrics.

## Reproduce and public references

```powershell
python -B cores/system/common_scaffold/image/affine_ransac/test_affine_ransac.py
python -B cores/system/common_scaffold/image/affine_ransac/synth.py
```

The independent Python arbitrary-precision oracle repeats exact sampling,
Cramer solves, signed rounding, range rejection, quantized reprojection and tie
rules. The TB compares every output bit with CE/gaps/backpressure and performs
two complete seed replays. Fixtures include affine translations of thousands
of pixels, rotation, scale/shear with25% outliers, noisy matches, random maps,
exact ties with different seeds, source/target collinearity, minimum3/full64
capacity, signed16 extrema, overflow rejection, FRAC0/8/16, bad count/budget/
capacity/markers and CE-low reset during capture, multiply, divide, scoring and
held output. Temporary input files/testbenches/binaries are automatically
removed. Compact evidence and synthesis logs remain.

Current complete regression has18 logical numerical cases /360 hypotheses,
each replayed twice in actual RTL: **36 complete results /720 hypotheses**.
Python classifies14 valid models,24 degenerate hypotheses and6 range rejections
across the18 logical cases. Additional config/marker/capacity errors and reset
streams are not included in those complete-result counts. Three invalid
elaboration parameter configurations are rejected explicitly.

Actual NumPy inlier least squares and OpenCV5.0.0 estimateAffine2D(RANSAC,
refineIters=0) are invoked on three exact synthetic affine/outlier datasets.
Both find the known24-of32 consensus. The RTL-equivalent matrices agree with
NumPy to about1.1e-11 (float reference rounding). This narrow synthetic result
does not imply bit/algorithm equality: OpenCV uses float models, L2 scoring,
different draws/termination and optional refinement.

Actually fetched public references, hashes in reference.json:

- [OpenCV estimateAffine2D implementation](https://raw.githubusercontent.com/opencv/opencv/4.x/modules/calib3d/src/ptsetreg.cpp).
- [OpenCV estimator API documentation](https://raw.githubusercontent.com/opencv/opencv/4.x/modules/calib3d/include/opencv2/calib3d.hpp).

Only mathematical/API behavior informed this independent RTL; no source code
was copied. No place/route, timing closure, board programming or physical
acceptance is claimed for this folder.

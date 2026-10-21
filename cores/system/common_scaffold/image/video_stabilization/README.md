# General affine video-stabilization matrix controller

`affine_video_stabilizer.sv` accepts a general two-dimensional affine transform
for each frame and computes accumulated camera trajectory, causal EMA smoothing,
forward stabilization and inverse-warp matrices entirely in RTL. It supports
translation, rotation, scale and shear; no host-side accumulation or inversion
is required. This core produces **matrices**, not sampled video pixels. Connect
the inverse-warp output to a frame sampler to obtain actual stabilized imagery.
It does not detect features, estimate motion, choose a crop or fill newly exposed
borders. A RANSAC estimator may supply its input after explicit format conversion.

## Coordinate direction and multiplication order

Points are homogeneous column vectors. An affine is stored in row order
`[a00,a01,a02,a10,a11,a12]`, with implicit last row [0,0,1]. All input/output
coefficients are **signed32 Q16.16**; translations are in pixel units, linear
terms dimensionless. Reset initializes internal T and S to identity.

For accepted input A mapping previous-frame coordinates to current coordinates:

```
T_new = A * T_old                # initial reference -> current camera frame
S_new = S_old + alpha*(T_new-S_old)  # smoothed initial-reference trajectory
C = S_new * inverse(T_new)       # current -> stabilized image coordinates
W = T_new * inverse(S_new)       # stabilized destination -> current source
```

Order matters: translation followed by rotation uses rotation*translation.
The tests include both orders. For an initial-reference scene point p, its
current location is T*p and desired stabilized location S*p. Thus C*T*p ~= S*p
and W*S*p ~= T*p; these point identities are tested independently of matrix
equality. W is the matrix for a backward/inverse-warp image sampler. C and W
are each formed using their own rounded inverses/composition, so they need not
be exact inverses after fixed-point quantization.

Smoothing is applied to the six affine coefficients, not decomposed angles or
the affine Lie group. It is a valid causal affine trajectory-filter variant,
but coefficient EMA can become singular between opposing rotations. Such a
candidate is **rejected with full state rollback**; it is never silently
replaced with translation-only motion or identity success.

cfg_alpha is unsigned17 UQ0.16, allowed0..65536. Zero keeps S fixed at its prior
value; 65536 selects T_new directly. Intermediate values blend trajectory.
cfg_min_inliers is unsigned7 and is compared with s_inliers at input acceptance.
cfg_min_det is unsigned64 in **raw Q32 determinant units**. The magnitude of
both T_new and S_new determinants must be strictly greater than this threshold;
zero rejects exact singularity only. Set a positive threshold to exclude a
known ill-conditioned region. This is not a complete condition-number bound.
Configuration is sampled/checked with each accepted input; later changes have
no effect on an active operation. No random seed is used: the algorithm is
fully deterministic, and complete reset/replay tests establish repeatability.

## Exact fixed-point arithmetic

For each matrix composition element, sum the two full Q32 products (plus a
translation shifted left16 where applicable), then round once to Q16:
`sign(sum)*floor((abs(sum)+32768)/65536)`. EMA multiplies the signed33-bit
difference by alpha, applies the same rounding, and adds the prior coefficient.
All ties round away from zero. Every narrowed result is explicitly checked
against signed32 range; overflow rejects the whole input operation.

For M=[a,b,tx;c,d,ty;0,0,1], form full determinant det=a*d-b*c. The inverse
linear entries are `[d,-b;-c,a]*2^32/det`, each **truncated toward zero** to its
Q16 integer representation. Cofactor negation has33 bits so -INT32_MIN is
representable. Translation is `-round16(inv_a*tx+inv_b*ty)`, similarly for y.
Every inverse entry has a signed32 range check. Very small but nonzero
determinants can therefore cause an explicit range rejection even with a zero
determinant threshold.

One shared signed33-by33 shift/add multiplier takes33 enabled cycles; it is
used for composition, EMA, determinant and inverse translation. Magnitudes are
formed at a fixed33-bit width **before** zero extension to66 bits, avoiding
context-sensitive unsigned-negation errors. Two signed32 products plus a Q32
translation, and determinant subtraction, use66-bit state so signed64 boundary
intermediates do not wrap. The inverse numerator magnitude is <=2^63 and fits
unsigned64. A shared64-cycle restoring divider uses a66-bit divisor and67-bit
remainder. No combinational general multiplier, host inverse or floating-point
hardware is used. All stored state is registered; no frame RAM is required.

The complete successful path is bounded by2500 enabled edges before result
presentation. Immediate scene-cut/config/confidence decisions take one edge;
arithmetic failures can return earlier. Input II is one **transaction**: a new
matrix is accepted after the preceding result handshake. This serial controller
does not claim a qualified video frame rate or routed frequency.

## Transactions, failure and reference alignment

Transfers require `rst_n && ce && valid && ready`. Reset is synchronous active
low, overrides CE, clears pending output and restores T=S=I. Do not count a
transfer during reset even if combinational s_ready is high. busy covers an
active operation and held result. Output consists of m_c00..m_c12 and
m_w00..m_w12, m_model_valid and error_code, qualified by m_valid. Every field
remains stable under m_ready backpressure and CE pauses. done pulses for one
**enabled cycle** following result acceptance, including error results; CE=0
holds the pulse. There is no separate done handshake.

Scene-cut has highest priority. An accepted s_scene_cut resets T/S to identity,
returns C=W=identity with m_model_valid=1/error0, and ignores input A, confidence
and otherwise-invalid configuration. The current frame becomes the new
reference. This is deliberate rebasing, not application of A.

| error_code | Outcome |
|---|---|
| 0 | Successful model, or explicit scene-cut rebase |
| 1 | s_inliers below configured minimum |
| 2 | T_new or EMA S_new determinant magnitude <= cfg_min_det |
| 3 | Accumulation, inverse, translation or compensation exceeds signed32 |
| 4 | cfg_alpha greater than65536 |
| 5 | Defensive illegal-state recovery |

Errors return all12 matrix fields zero and m_model_valid=0. Consume the held
error record normally with m_ready. **T and S are committed together only after
all arithmetic succeeds**; all error cases roll back both states.

Consequently, after a rejected frame, the caller must supply motion from the
**last successfully accepted camera frame** to its next frame, or send
s_scene_cut to rebase. It must not blindly resume ordinary adjacent-frame
transforms after skipping a failed frame. This core has no image data or frame
IDs with which to repair such a reference mismatch. The tests deliberately
check rollback with inputs aligned to the retained reference.

## Reproduce and numerical evidence

```powershell
python -B cores/system/common_scaffold/image/video_stabilization/test_stabilization.py
python -B cores/system/common_scaffold/image/video_stabilization/synth.py
```

An independent Python arbitrary-precision model computes every staged rounded
operation, inverse, rejection and transactional rollback. RTL outputs are
compared bit for bit across two complete reset/replays. Testcases include
noncommuting translation/rotation, scale/shear, a100-frame small-motion chain,
20 additional randomized affine steps, alpha endpoints, signed fractions,
low confidence, scene-cut precedence, T singularity, EMA singularity and
near-singularity, input/cofactor INT32_MIN, huge determinant intermediates,
inverse and accumulated-translation range overflow. Configuration is changed
while busy to check snapshots. CE/output backpressure, CE-low input nontransfer,
and reset during multiply, divide, EMA, determinant and held output are tested.

Actual NumPy float64 independently accumulates and smooths full3x3 trajectories
and uses np.linalg.inv. It measures fixed-point error and synthetic point
mapping consistency. These are fixture measurements, not global accuracy
bounds: near-singular matrices and large repeated transforms can magnify staged
fixed-point drift. See evidence.json for counts and maximum measured errors.
Temporary testbenches, vectors and binaries are automatically removed; compact
JSON evidence and synthesis logs remain. No timing closure or board acceptance
is claimed.

Current results: **166 logical transactions /332 complete RTL replay results**,
157 successful logical models and9 explicit rejections (1 low-confidence,
1 illegal-alpha,4 determinant and3 range failures). Against NumPy, maximum
coefficient error across the recorded sequence is0.0012312262. Inverse-warp
point consistency W*S*p versus T*p has maximum error0.0031688782 pixel over
the test points. Forward C*T*p versus S*p is also audited on well-conditioned
fixtures (condition number<100 and trajectory coefficients<1000), maximum
0.0033746115 pixel. These forward-fixture qualifications avoid implying a
uniform error guarantee near singularity.

Isolated Gowin `synth_gowin -noalu -nodsp` passes CHECK with zero problems:
**7789 LUT1..4,2982 FF,608 MUX5,0 DSP,0 RAM**. This meets the requested15K
LUT/4DSP isolated limit; top-level I/O buffers are included and no routing or
frequency qualification is inferred.

The separate integration test `integration/test_ransac_stabilization.py` has
also passed9 frames /216 matches /432 RANSAC hypotheses with6 outliers per
frame. It runs the actual affine estimator, converts Q8 signed40 to Q16
signed32, and feeds this controller. Independent Fraction Gauss–Jordan matrices
check noncommuting translation/rotation/shear/scale, EMA, scene-cut rebasing and
low-inlier rejection. Evidence is outside this folder at
`../../evidence/ransac_stabilization_20261018T224116Z_bebc269c`.

## Public reference

Actually fetched [OpenCV videostab motion smoothing implementation](https://raw.githubusercontent.com/opencv/opencv_contrib/4.x/modules/videostab/src/motion_stabilizing.cpp);
reference.json records its hash and the GaussianMotionFilter excerpt. It
illustrates composing relative camera motion and smoothing stabilization
matrices. This core uses its own specified **causal coefficient EMA**, not
OpenCV's Gaussian temporal window or LP optimizer, and does not claim identical
outputs. The RTL and exact arithmetic model are independently implemented; no
source code was copied.

# Perspective homography RANSAC

`homography_ransac.sv` estimates a genuine 3×3 perspective transformation from 4–64 signed integer point pairs. It generates four-point hypotheses, rejects every source or destination sample containing any collinear triple, solves eight homography unknowns, scores all loaded points by actual perspective division, and refits the best consensus using **all its inliers**. The refitted model is scored again before output. It is not an affine alias and does not require host-computed coefficients.

## Interface and numerical contract

- `s_x/s_y/s_u/s_v`: signed 16-bit ports, supported integer range **−127…127**. Coordinates outside this range fail explicitly.
- `cfg_count`: 4…64; `cfg_iterations`: 1…65535 four-point hypothesis attempts. Degenerate/overflowing attempts consume budget and are counted.
- `cfg_seed`: deterministic xorshift32 seed; zero is canonicalized to one. Distinct sample indices use rejection sampling. A finite RANSAC budget does not guarantee finding the global best model.
- `cfg_threshold`: unsigned **Q16 pixel Manhattan reprojection error**, inclusive. Both source and destination coordinates are divided by 128 internally; matrix arithmetic is signed Q24.
- `h00…h22`: signed **64-bit Q24** coefficients in the original pixel coordinate system, with `h22=1<<24`. Evaluate `u=(h00*x+h01*y+h02)/(h20*x+h21*y+h22)`, similarly for v.
- `inlier_mask`: final refitted-model classification; `best_count`: its population count; `best_residual`: summed inlier Manhattan residual in **Q16 pixels**. Residual scoring precedes the final Q24 rounding of the two perspective coefficients, so recomputing it from output H can differ slightly.
- `refit_mask`: the complete best-consensus set actually used for the least-squares refit. Reclassification can add or remove inliers; there is one refit, not an unbounded iterative refinement loop. The 64-point fixture refits 45 consensus points and classifies 50 final inliers.
- `hypotheses`, `degenerate_count`, `overflow_count`: 16-bit attempted/rejected statistics, meaningful for well-formed captures. A malformed capture has no valid model; other payload outputs must be ignored when `model_valid=0`.

Assert `s_first` on the first accepted pair, `s_last` on pair `cfg_count−1`, and neither elsewhere. Configuration is sampled on the first pair. Transfer is `ce && valid && ready`; hold input data until accepted. Capture is sequential, with no separate start command. `busy` identifies computation; a partial capture has `busy=0` and is indicated by input progress. `m_valid`/`done` hold the complete result until `ce && m_ready`. All result fields remain stable during that hold. A new capture is permitted after acknowledgement without reset. Synchronous active-low reset takes priority over CE and cancels partial capture, arithmetic, scoring or held completion. There is no separate abort port; reset cancels a transaction.

## Solver and bounded failures

Each point contributes the two standard equations for eight unknowns with H22 fixed to one. A serial outer-product accumulator forms an 8×9 augmented normal system; partial-pivot Gauss-Jordan elimination solves it. The same datapath and solver process every four-point candidate and the full consensus refit. This is algebraic least squares; OpenCV's nonlinear geometric refinement need not return identical coefficients.

Point storage and the augmented matrix use clocked reads. One serial 64×64 signed multiplier accumulates into 128 bits, shifts by 24 and checks representability. One shared restoring divider computes a 128-bit shifted numerator over a 64-bit denominator, with explicit zero/overflow detection. No combinational multiplier/divider operator is used for these operations. Multiplication by fixed powers of two is a shift after synthesis.

All four source and destination triples must have nonzero exact integer cross product. A solver pivot smaller than 16 Q24 units is rejected as ill-conditioned. Any solved normalized coefficient outside ±(2^40−1) is rejected as overflow/range failure. Projection denominators with absolute value below 256 Q24 units are unscorable and produce no inlier. This threshold also bounds projection arithmetic. Addition/subtraction during matrix accumulation/elimination is checked. Normal equations worsen conditioning; this bounded fixed-point solver is not a replacement for floating-point normalized DLT/SVD on arbitrary coordinate ranges. Homographies requiring H22=0, nearly singular scenes, or unsupported coordinates can fail explicitly rather than produce a valid result.

Error codes:

| Code | Meaning |
|---|---|
| 0 | Successful refit and at least four final inliers |
| 1 | Count outside 4…64 or zero hypothesis budget |
| 2 | Input first/last protocol or coordinate range violation |
| 3 | Budget exhausted without a usable four-inlier consensus |
| 4 | Final consensus refit degenerate or overflowing |
| 5 | Refitted model has fewer than four final inliers |
| 6 | Unsupported internal state |

Rejected candidate arithmetic increments `overflow_count`; degeneracy increments `degenerate_count`. Candidate failure continues to the next attempt. Refit failure completes with `model_valid=0` and error 4. Consume an error completion to reuse the module; reset is also always available.

## Reproduce verification

From the repository root:

```powershell
python -B cores/system/common_scaffold/image/homography_ransac/test_homography_ransac.py
python -B cores/system/common_scaffold/image/homography_ransac/test_edges.py
python -B cores/system/common_scaffold/image/homography_ransac/synth.py
```

The main test builds exact Fraction normal equations independently from `refit_mask`, compares resulting pixel projections with RTL, and invokes actual `cv2.findHomography` RANSAC. Fixtures cover a non-affine quadrilateral, random perspective with outliers, exact integer perspective, full 64-point capacity with 14 outliers, source/destination degeneracy, range rejection, deterministic replay without reset, CE gaps, and held-result stability. OpenCV inlier counts must match and common-inlier projected coordinates must agree within one pixel. Fraction projection error must be below 0.08 pixel; observed errors are below 0.001 pixel on these fixtures. Tests demonstrate fixture behavior, not a universal accuracy guarantee.

`test_edges.py` tests actual serial signed arithmetic, injected multiplication/division overflow and zero divisor, malformed input, and CE-low reset in partial capture, matrix clear, multiplication, division, scoring and held DONE. Overflow injection tests the arithmetic datapath explicitly; it is not presented as an overflowing real-image fixture. Full functional recovery follows resets.

Full isolated `synth_gowin -noalu -nodsp; check -assert` passes: **9059 LUT1…4, 3739 FF, 48 RAM16SDP4, 4 SDPX9B, 0 DSP**, plus mux cells recorded separately in `synthesis.json`. This is below the 15K LUT/4 DSP isolated-module target. It is not a routed timing, full-system resource or board-validation claim. The many scalar result ports are intended for internal integration and exceed physical board I/O if exposed directly. Latency is intentionally serial and scales with hypothesis budget and point count.

Temporary simulation and synthesis files are deleted automatically. Only compact JSON evidence, references and a synthesis statistics log remain.

## References

OpenCV [fundam.cpp](https://github.com/opencv/opencv/blob/4.x/modules/calib3d/src/fundam.cpp) and [ptsetreg.cpp](https://github.com/opencv/opencv/blob/4.x/modules/calib3d/src/ptsetreg.cpp) were fetched and reviewed for four-point homography, collinearity checks, consensus and refit conventions. URLs and fetched SHA256 hashes are in `reference.json`. The RTL and Fraction oracle are independently written; no external implementation code was copied.

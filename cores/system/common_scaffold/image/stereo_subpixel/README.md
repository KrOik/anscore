# Complete cost-axis WTA and exact quadratic subpixel disparity

`stereo_subpixel.sv` consumes every disparity cost for every pixel, finds the actual winning and second-best valid costs, retains the winning point's real adjacent costs, and computes subpixel disparity in RTL. No host-selected minimum or host-computed interpolation is accepted. This is a cost-volume postprocessor, not a replacement cost metric, SGM aggregator, stereo calibration or left/right consistency check.

## Exact numeric contract

WIDTH/HEIGHT1..4096, total pixels<=65536; DISPARITIES3..256, unsigned COST_BITS2..24, FRAC_BITS1..12. Each pixel must contain exactlyD accepted beats with s_disp0..D-1 in ascending order. An invalid cost beat still occupies its disparity index but is excluded from WTA and second-best selection. The smallest cost wins; ties choose the smallest disparity index. The second-best cost includes ties at other valid indices. `m_confidence=second-best-best` (absolute unsigned cost gap), or0 if fewer than two costs are valid.

For an interior winner with valid adjacent costs, the exact offset is:

```
delta = (Cleft-Cright) / (2*(Cleft-2*Cbest+Cright))
```

The core performs unsigned long division on the signed numerator magnitude scaled by2^FRAC_BITS, rounds to nearest with exact half ties away from zero, restores sign and explicitly clamps to[-0.5,+0.5]. `m_integer` is the unsigned WTA index, `m_offset` is the signed offset in FRAC_BITS units, and signed32 `m_disparity_q=(m_integer<<FRAC_BITS)+m_offset`. Thus a negative offset can borrow from the integer component; m_integer remains the WTA index, not the floor of the final refined disparity. No floating-point approximations, reciprocal tables, truncation of cost differences or divisors are used.

`cfg_min_gap` is an inclusive absolute-gap confidence requirement: gap>=threshold passes. Default1 rejects equal-cost ties; setting0 deliberately permits them. It is not OpenCV's percentage uniqueness ratio and does not exclude neighboring disparities from the second-best search. The configuration is accepted only before the first disparity of the first pixel, takes priority over input, and is snapshotted for the entire frame. Fewer than two valid costs, no valid costs, or insufficient gap sets m_invalid. A low-gap result still reports the computed numerical offset and its status so a downstream policy can inspect it.

A boundary winner or invalid adjacent cost emits an integer fallback, without making an otherwise confident result invalid. A downstream requiring refined-only values must check status bit0. An all-invalid axis reports index0/disparity0/confidence0 and invalid1; a single-valid-cost axis reports that integer but invalid1. Unrelated nonconvex parts of the full curve do not bypass global WTA.

| m_status bit | Meaning |
| --- | --- |
| 0 | Quadratic interpolation actually completed |
| 1 | Winning disparity is0 orD-1; integer fallback |
| 2 | An adjacent disparity cost is invalid; integer fallback |
| 3 | Nonpositive curvature; defensive integer fallback |
| 4 | Absolute confidence gap below the frame threshold |
| 5 | Fewer than two valid costs |
| 6 | No valid costs |
| 7 | Rounded offset required defensive clamping |

Bits0/1/2/3 describe the path; bits4/5/6 report confidence/validity; bit7 is a defensive condition. Invalid outputs still carry normal pixel markers and must be consumed.

## Arithmetic bounds and unreachable defensive branches

For a true interior global WTA with valid neighbors, a=Cleft-Cbest>=0 and b=Cright-Cbest>=0. The first-minimum tie rule additionally gives a>0, because the valid left neighbor has an earlier index. Therefore curvature=a+b>0 and |a-b|<=a+b, so the exact offset is always within±0.5. Round-half-away cannot escape that bound because0.5 is exactly representable for FRAC_BITS>=1. Nonpositive curvature and clamping status are defensive guards; they are mathematically unreachable under legal full-axis WTA inputs and are not claimed as physically exercised branches. Flat curves and tied minima are tested through their actual boundary/uniqueness behavior.

At COST_BITS24/FRAC_BITS12, the largest shifted numerator is68,719,472,640 (<2^36), the largest doubled curvature is67,108,860 (<2^26), and the fixed disparity fits signed32 even forD256. Signed COST_BITS+3 neighbor arithmetic, a32-bit denominator,33-bit remainder and64-bit numerator/quotient cover those bounds. Joint24-bit-cost/Q12 extreme-neighbor tests verify the actual RTL shift context, rather than relying on separate widest-format tests.

## Frame protocol, completion and recovery

s_sof/s_eol/s_last describe the current pixel and must be repeated consistently on every cost beat of that pixel: SOF for pixel0, EOL for the last pixel in each row, LAST for the last pixel of the frame. Every transfer requires rst_n && ce && valid && ready. Producers hold cost, invalid mask, disparity index and markers until accepted. Outputs remain stable under backpressure or CE pause. There is one active pixel; input pauses during interpolation and output holding. No complete cost curve RAM is required.

After the final result is consumed, done_valid remains asserted until done_ready is accepted. A missing/extra/reordered disparity index or wrong marker terminates the frame with frame_error1/error_code1. Illegal-state recovery uses2, explicit abort uses3. Prior results already accepted before an error are a partial frame and must be rejected by clients requiring complete-frame validity. There is no missing-beat timeout or autonomous stream resynchronization. After done acknowledgment, discard any remaining old input and restart a whole frame from pixel0/disparity0/SOF.

Abort suppresses s_ready/m_valid immediately and is sampled on an enabled clock edge; hold abort through at least one ce1 edge, then acknowledge error completion. A CE-disabled pulse that ends before an enabled edge is not a completed abort request. Reset is synchronous active-low, overrides CE, aborts pending input/division/output and resets the configured minimum gap to1. Reconfigure as needed and provide a new whole frame after reset. Registered fields outside valid/completion are not payloads.

## Mature-source comparison and validation

The network reference was actually retrieved through jsDelivr's OpenCV mirror after raw.githubusercontent.com timed out. references.json records the source URL, SHA256 and excerpts around OpenCV's quadratic interpolation. No third-party RTL was copied. The curvature formula matches that mature implementation, but numerical and confidence policies are explicit variants. OpenCV's inspected C++ expression `((L-R)*DISP_SCALE+curvature)/(2*curvature)` uses signed division truncating toward zero; this core instead rounds signed values symmetrically, ties away from zero. Example L3/B0/R7 atQ4: this core offset-3, the inspected C++ expression-2. A10000-curve expression audit records these differences (at most oneQ4 unit in its tested domain). This is not a full OpenCV StereoSGBM equivalence claim.

Commands from repository root:

```
python -B cores/system/common_scaffold/image/stereo_subpixel/run_tests.py
python -B cores/system/common_scaffold/image/stereo_subpixel/run_synthesis.py
```

The main test runner executes Fraction-oracle numeric tests, then test_protocol.py, test_numeric_limits.py and test_reference_variant.py; those three are also independently executable. The network fetch helper is optional provenance refresh and is not needed for numerical tests. There are2480 complete axes:144 each forD16/B16/Q4, D32/B24/Q8 and D32/B24/Q12, plus2048 exhaustiveD3/B2/Q12 axes (all64 cost triples,8 invalid masks,4 gap policies). Cases include ties, boundary minima, all/one valid costs, invalid neighbors, nonconvex curves, maximum costs and signed offset directions. Protocol tests add13 complete2x2 healthy frames/52 pixels,5 packet errors,3 abort phases,3 CE-disabled reset phases and atomic frame gap configuration. Eleven invalid parameter profiles are rejected. Temporary simulation/synthesis/reference downloads are removed; logs, manifests and bound evidence remain. No board/timing/image-quality signoff is claimed.

Final Gowin synthesis (`synth_gowin -noalu -nodsp`, `check -assert`):

| Profile | LUT-class incl. MUX/LUTRAM | FF | DSP | BRAM/LUTRAM |
| --- | ---: | ---: | ---: | ---: |
| D16/COST16/Q4 | 1073 | 560 | 0 | 0 |
| D32/COST24/Q8 | 1262 | 628 | 0 | 0 |

Both full standalone cores remain below15K LUT-class and4DSP. No arithmetic module or memory is hidden in a black box. Resource counts are isolated synthesis results; there is no place-and-route, qualified clock or board claim.

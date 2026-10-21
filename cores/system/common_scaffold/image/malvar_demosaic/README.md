# Malvar–He–Cutler 5×5 Bayer demosaicing

`malvar_demosaic.sv` is a complete frame-buffered **Malvar–He–Cutler (MHC) linear demosaicer**. It captures a scalar Bayer frame, performs the actual signed5×5 MHC convolutions and emits same-size `{R,G,B}` pixels. It is not bilinear interpolation or a pass-through adapter. The measured Bayer sample is retained exactly in its original color channel; only missing channels are interpolated.

WIDTH/HEIGHT are static1..256, BITS is8/10/12; default32×24/8bit. Pattern ABI matches the existing ISP modules: **0 RGGB,1 GRBG,2 GBRG,3 BGGR**. cfg_pattern is snapshotted on accepted START, and changes while the frame is processing have no effect. For green samples, horizontal/vertical red/blue kernel assignment follows the actual Bayer row parity. There is no automatic CFA detection, black-level subtraction, white balance, gamma or color-matrix operation.

## Exact kernels and arithmetic

The following integer matrices are divided by16, with only one final rounding per reconstructed channel:

```
Green at red/blue:
 0  0 -2  0  0
 0  0  4  0  0
-2  4  8  4 -2
 0  0  4  0  0
 0  0 -2  0  0

Horizontal color at green (vertical is its transpose):
 0  0  1  0  0
 0 -2  0 -2  0
-2  8 10  8 -2
 0 -2  0 -2  0
 0  0  1  0  0

Red at blue / blue at red:
 0  0 -3  0  0
 0  4  0  4  0
-3  0 12  0 -3
 0  4  0  4  0
 0  0 -3  0  0
```

Signed accumulators are BITS+7 bits. The largest absolute coefficient sum is40, so for maximum unsigned sample P=2^BITS-1 every partial sum has magnitude<=40P. This plus the rounding bias8 is strictly inside the accumulator's signed range±2^(BITS+6). Constant weights are implemented as signed shift/add, including negative weights; no unsigned intermediate or signed16 truncation is introduced. Reconstruction is `clip((signed_sum+8)>>>4,0,P)`: nearest integer with half ties toward positive infinity, followed by saturation. Negative overshoot is clipped0; positive overshoot is clippedP. Original color samples bypass this quantizer and remain exact. All three kernels sum to16, so uniform scalar Bayer input produces uniform RGB.

## Full-frame boundary policy

Every5×5 tap uses **REFLECT101**, equivalent to SciPy `ndimage.convolve(...,mode='mirror')` and OpenCV BORDER_REFLECT_101. A tap outside an edge reflects without repeating the edge sample: for length5, indices-2,-1,0,1 map2,1,0,1; indices4,5,6 map4,3,2. Length1 maps every tap to0. Length2 and other thin images use repeated reflection until the tap lies in range, not a one-step correction that can leave negative indices. The full same-size raster is output, including the outer two rows/columns; no crop or unspecified border is hidden.

One synchronous frame RAM read is followed by an accumulation cycle for each of25 taps. The frame RAM is never reset; capture overwrites the complete frame before processing, and malformed capture terminates without output. This conservative whole-frame implementation has serialized throughput, not a one-pixel-per-clock or camera-rate claim. Synthesis proves actual DPX9B inference at the default32×24 geometry for every supported bit depth.

## Interface and recovery

Ports are clk/rst_n/ce; start_valid/start_ready, cfg_pattern[1:0], abort; input s_data/s_valid/s_ready/s_sof/s_eol/s_last; output m_data[3*BITS-1:0] packed `{R,G,B}`, m_valid/m_ready/m_sof/m_eol/m_last; done_valid/done_ready/done_error/error_code/busy.

All transfers require enabled valid/ready on a rising edge. Input readiness is suppressed during reset, CE=0 and abort. Output tokens and terminal DONE hold across backpressure/CE pauses. Input markers must identify only the first pixel, each source row end and final source pixel. A marker error terminates immediately, including partial frames; the sender need not finish the malformed frame. Output markers are regenerated from geometry.

Reset is synchronous active-low and overrides CE, discarding incomplete capture/convolution/output. Abort immediately suppresses output and becomes held error on an enabled edge; keep it asserted through that edge. An abort during replay invalidates the entire frame, including previously sent pixels. A late abort does not alter held DONE. Acknowledge DONE before starting another frame; no reset is needed between healthy frames or after an acknowledged error. Error codes:80 unsupported static geometry/BITS,81 source-marker mismatch,93 active abort,94 internal state. Geometry/frame size is known; a producer that stops without completing a frame must abort/reset because no input watchdog is claimed.

## Independent and mature-reference evidence

run_tests.py uses independently specified2D mathematical kernel arrays, SciPy mirror convolution, parity masks and exact signed numerator quantization. RTL reads every tap serially; the oracle performs full2D convolutions. Tests cover all four patterns, all8/10/12bit modes, constant/impulse/random/synthetic RGB-mosaic scenes, cfg_pattern changes after START, CE and output stalls, repeated frames, dimensions1×1/1×2/2×1/1×7/7×1/2×2/2×9/9×2 and default32×24.

The actual mature `colour-demosaicing` Malvar2004 implementation was downloaded, hashed and **executed**, not merely cited. The original function was extracted as Python AST and executed with NumPy/SciPy helper bindings; its original kernel and channel-selection code was retained in execution. Twelve deterministic CFA fixtures cover every pattern and bit depth. Its default SciPy boundary is `reflect` (edge-repeating), while this RTL selects `mirror`/REFLECT101. The unmodified function was therefore executed twice: once with its native reflect convolution, and once with only the convolve helper explicitly using mirror to align boundary policy. Both numerical differences are recorded. Final integer rounding/saturation is applied explicitly because the mature function returns unclipped floating RGB.

Same-boundary mature-reference and RTL results are exactly equal in the recorded fixtures; native reflect results match the interior beyond the2-pixel boundary but differ at borders by up to2576 at12bits. This is a disclosed boundary-policy difference, not a hidden tolerance or claim of default library bit-equivalence. Frozen numeric fixtures are stored in **reference_fixtures.mem** (JSON-formatted numeric data using a tracked fixture extension). test_reference.py sends those exact inputs through RTL and verifies their mature-reference outputs. Thin-image behavior is validated with the independent mathematical oracle, because the mature function's squeeze/row-mask behavior is not a suitable universal oracle for1-pixel dimensions.

refresh_reference.py is an optional reproduction utility: it downloads the public reference into a temporary directory, requires the previously reviewed source SHA256, executes both boundary variants and deterministically regenerates frozen numeric fixtures. It refuses an upstream source change instead of silently changing expected outputs. Routine tests use the frozen fixtures and do not require network access. Original RTL was authored independently; no third-party source is retained/copied into the design. References and downloaded SHA are in references.json.

Protocol tests abort all six active phases (capture, initialization, RAM read, accumulation, rounding, held output), inject two malformed marker variants, hold DONE, recover healthy frames and reset during convolution with CE=0. Numeric stress fixtures independently force each kernel's positive saturation and negative clamp at all bit depths, rather than testing only low-valued images.

## Reproduce and resource limits

```powershell
python -B cores/system/common_scaffold/image/malvar_demosaic/run_tests.py
python -B cores/system/common_scaffold/image/malvar_demosaic/test_reference.py
python -B cores/system/common_scaffold/image/malvar_demosaic/test_numeric_limits.py
python -B cores/system/common_scaffold/image/malvar_demosaic/test_protocol.py
python -B cores/system/common_scaffold/image/malvar_demosaic/synth.py
```

Default32×24 isolated synthesis:8bit=1127 LUT-class/4 DPX9B,10bit=1227/5 DPX9B,12bit=1306/6 DPX9B, all0 DSP. The counter includes LUT/ALU/MUX and conservatively4 equivalents per RAM16SDP4 (none inferred in these profiles). `check -assert` passes and synthesis asserts nonzero block-RAM inference. These are synthesis resource results, not post-route timing, board acceptance or full-resolution image-quality signoff. JSON evidence binds the RTL SHA; reference evidence additionally freezes fixture/source hashes. Temporary simulation/synthesis files and downloaded source copies are cleaned after use.

# Gaussian unsharp-mask sharpening

`unsharp_mask_frame.sv` implements actual Gaussian low-pass, detail extraction,
thresholding, configurable detail gain and saturated reconstruction. It does
not merely increase contrast or select a precomputed palette. The repository
RTL/manifest search for unsharp/high-boost found no existing complete kernel.

Parameters WIDTH and HEIGHT support 1..32 each (at most 1024 pixels), and
CHANNELS is 1 (gray byte) or 3 (packed RGB `{R,G,B}`). Processing is independent
per channel, with one shared serial gain multiplier. All frame RAM reads are
synchronous. A complete frame is captured before filtering; no host-precomputed
blur or coefficients are supplied. Replicated image borders explicitly clamp
each neighbor coordinate to the nearest valid image coordinate, including
1x1, 1xN and Nx1 geometries.

For each channel sample s, the exact arithmetic is:

```text
S = sum(image[x+dx,y+dy] * wx * wy), wx,wy = [1,2,1]
low = floor((S + 8)/16)
detail = s - low
if abs(detail) > threshold:
    boost = sign(detail) * floor((abs(detail)*gain + 8)/16)
else:
    boost = 0
output = clip(s + boost, 0, 255)
```

The 3x3 kernel is the binomial Gaussian `[1,2,1]ᵀ[1,2,1]/16`, identical to
OpenCV `GaussianBlur(...,(3,3),0,BORDER_REPLICATE)` for this byte interface.
It is a fixed Gaussian kernel, not an arbitrary sigma/large-radius engine.
`cfg_gain` is unsigned Q4.4 (0..15.9375); 16 means 1x detail. Gain zero is
an exact bypass. `cfg_threshold` is an unsigned gray-level threshold, with
equality **suppressed**; 255 suppresses all detail. Both low-pass and signed
gain rounding are explicit; halfway gain magnitudes round away from zero.
Only final output clips. `clipped_samples` counts channels whose reconstructed
value was below 0 or above 255, not already-in-range endpoint values. Its
13-bit range covers the maximum 3072 samples.

START snapshots gain/threshold atomically. Changes to raw configuration while
busy have no effect. Pixel input/output and START require CE and valid/ready.
SOF marks only the first pixel, EOL every row end, and LAST only the final
pixel. Data and all output markers hold through backpressure and CE stalls.
DONE follows consumption of the final output pixel and remains held until
CE-qualified done-ready. Busy includes pending DONE. Statistics hold until
the next valid START. There is no independent abort input: reset aborts.

Active-low synchronous reset overrides disabled CE, cancels pending output
and completion, and gates ready low while reset is asserted. Frame RAM is not
reset; every new frame completely overwrites its used memory first.

Error 1 rejects unsupported static geometry/channel parameters without
accepting input or emitting output. Error 2 records SOF/EOL/LAST mismatch;
the engine still captures, processes and emits exactly N pixels before held
error completion. Error 3 handles an invalid internal control state. Fewer
than N supplied pixels wait for completion or reset. There is no undocumented
error alias to a normal pass. All gain/threshold bit patterns are valid, so
runtime configuration has no artificial forbidden values.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/unsharp_mask/run_tests.py
python -B cores/system/common_scaffold/image/unsharp_mask/run_synthesis.py
```

The independent integer oracle checks every RTL output/marker and exact
clipping count. The regression covers 116 complete frames / 16646 pixels:
gray/RGB, six geometry/channel combinations including maximum 32x32,
constants, impulses, negative impulses, checkerboards, random frames,
threshold equality, gain/threshold extremes, atomic configuration, CE and
output stalls, held DONE, all three marker errors, five invalid parameter
profiles, and 36 full healthy recovery frames after six CE-low reset stages
per profile (capture, RAM read, Gaussian read, multiply, held output, DONE).

Actual OpenCV GaussianBlur is checked **exactly** for every numerical fixture.
Actual OpenCV addWeighted implements the same rounded low-pass unsharp
expression with the same per-channel threshold gate. Its final rounding can
choose a different integer at halfway values; the asserted maximum output
error is **1 LSB**, with measured per-frame errors retained in JSON. This is
a numerical implementation bound, not an image-quality improvement claim.
scikit-image unsharp-mask and OpenCV smoothing sources were actually fetched;
URLs, sizes, UTC times and SHA256 appear in `references.json`. No upstream
code is copied.

Isolated Gowin synthesis passes `check`: 7x5 gray uses 432 LUT1..4, 52 MUX5,
156 FF and 6 RAM16SDP4; 7x5 RGB uses 509 LUT1..4, 90 MUX5, 204 FF and
18 RAM16SDP4; 32x32 RGB uses 479 LUT1..4, 65 MUX5, 244 FF and 2 DPX9B.
All use 0 DSP, within 15K LUT-class / 4 DSP. This is a serial frame engine,
without video-rate, arbitrary-size, routed-timing or board-acceptance claims.
Exact cell and source hashes are frozen in the small evidence JSON files.
Generated testbenches, vectors, binaries and netlists use TemporaryDirectory
and are automatically removed; no large build products are retained.

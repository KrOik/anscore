# D65 sRGB888 ↔ CIELAB8 stream converter

`rgb_cielab_stream.v` implements the complete standard conversion: sRGB transfer
decoding, linear RGB→D65 XYZ matrix, CIE piecewise Lab transform, and its inverse
with XYZ→linear RGB matrix and sRGB transfer encoding. It does not substitute
RGB channel combinations for Lab. Input RGB is nonlinear standard sRGB with D65
white, not raw linear sensor data. No D50 chromatic adaptation is performed.

The 24-bit stream has channels in bits 23:16 / 15:8 / 7:0. RGB uses R/G/B order.
Lab uses OpenCV's byte representation: `L8=round(L*255/100)`,
`a8=round(a)+128`, `b8=round(b)+128`, each saturated to 0..255. Inverse decoding
uses L=L8*100/255, a=a8-128, b=b8-128. This encoding is lossy, especially for
saturated colors with small RGB channels; byte RGB→Lab→RGB is not an identity operation.

## Frame API

`rst` is active-high synchronous and takes precedence over `ce`. It aborts a
frame, pending output, and completion. START transfer is
`ce && start_valid && start_ready`; it snapshots `cfg_inverse` (0 forward,
1 inverse). Changes to direction or START while busy have no effect. `WIDTH`
and `HEIGHT` are positive static parameters with product at most 65536.

Each frame consumes exactly WIDTH×HEIGHT pixels in row-major order. Input
transfer is `ce && s_valid && s_ready`; output transfer is
`ce && m_valid && m_ready`. Output payload, markers, and valid stay held under
backpressure or CE=0. Ready signals are low during reset/CE=0; valid remains
visible while CE=0 and must be qualified with CE by consumers. A single pixel
is processed at a time. This area-oriented serial arithmetic does not promise
one pixel per clock. There is no frame RAM or external multiplier dependency.

Input SOF must identify only pixel zero and EOL each final column. Output
markers are regenerated from geometry. Sticky `done_error` and `error_code`
report bit0 missing SOF, bit1 extra SOF, bit2 missing EOL, bit3 extra EOL; all
bits set also identifies an illegal internal state. Malformed markers do not
change the pixel count: processing continues, and the consumer must discard
the whole frame including any previously emitted prefix if an error occurs.

`done_valid` asserts after final output transfer and remains held until
`ce && done_valid && done_ready`. Busy includes unacknowledged completion.
After acknowledgement, another START is accepted and clears errors. Completion
cannot be overwritten by a START. Reset provides explicit early cancellation.

## Fixed-point design and ROM assets

Linear RGB, normalized XYZ, Lab f-coordinates and matrix coefficients use Q16.
Signed matrix products accumulate in 64 bits through one shared 32-cycle
shift-add multiplier. A shared serial unsigned divider encodes L8. Matrix
coefficients are in `coefficients.json`; positive forward rows are adjusted by
at most a few Q16 units so each sums to 65536, preserving neutral white.

`decode.mem` is a 1024×19-bit signed synchronous ROM containing 256 exact sRGB
decode entries, L→fy values, a→fx offsets and b→fz offsets.
`nonlinear.mem` is a 4096×26-bit signed synchronous ROM with:

- 1025 CIE f entries over normalized XYZ [0,1], spacing 1/1024;
- 1025 inverse-sRGB entries over linear [0,1], spacing 1/1024;
- 1281 inverse-CIE f entries over [-0.5,2], spacing 1/512;
- zero padding to the power-of-two storage size.

Adjacent entries are linearly interpolated using the shared multiplier. The
piecewise equations use the exact CIE threshold δ=6/29 and ε=δ³, sRGB decode
threshold 0.04045 and encode threshold 0.0031308. Inverse Lab's full encoded
domain fits inside the inverse-f ROM interval. Negative XYZ is preserved
through the inverse matrix; final linear RGB is clipped to [0,1] before gamma
encoding, explicitly handling out-of-gamut Lab values.

ROM generation and signed Q16 shifts use nearest rounding with halfway values
away from zero. Interpolation uses nearest rounding upward. L8 division is
nearest upward; final channels saturate to byte range. Nonlinear inverse-gamma
ROM values retain fractional byte units (Q16 times 255), not prematurely
rounded 8-bit entries.

Parameters `DECODE_FILE` and `NONLINEAR_FILE` default to `decode.mem` and
`nonlinear.mem`. Run tools with this directory as cwd or override these
parameters with absolute asset paths. Deliver both ROM files with the RTL.
`generate_tables.py` reproducibly regenerates them using Python math; fetching
sources is optional through `--fetch` and an optional `--proxy` URL.

## Verification and limitations

From the repository root:

```powershell
python -B cores/system/common_scaffold/image/cielab_color/run_tests.py
python -B cores/system/common_scaffold/image/cielab_color/synth_cielab.py
```

The actual RTL stream is checked byte-for-byte against `oracle.oracle`, an
unbounded integer matrix/interpolation model. `oracle.mathematical` independently
implements direct floating CIE/sRGB equations without any ROM access. Tests
include random colors, all 256 RGB gray levels, all 256 neutral Lab L levels,
corners/near-extremes, inverse out-of-gamut saturation, and actual alternating
forward/inverse stream transactions. OpenCV 5.0.0 is actually invoked in both
directions. Observed per-channel maximum differences are forward [1,2,1] and
inverse [1,1,1] versus OpenCV, and at most 1 versus direct CIE formulas. OpenCV
uses slightly different matrix constants, transfer-table precision and rounding;
bit-exact OpenCV matching is not claimed. `test_result.json` records measured
RGB roundtrip error and independent/OpenCV roundtrip comparisons.

Additional coverage comprises 10 multiline frames / 60 pixels with all four
marker-error types and recovery in both directions, 9 processing-phase resets
while CE=0 with 9 subsequent healthy frames, held output/completion, ignored
busy direction changes, and 4 invalid geometries. Generated testbenches,
executables and synthesis workspaces use `TemporaryDirectory` and are removed.

Complete isolated Gowin mapping, including both ROMs, passes `check -assert` at
16×16, 31×33 and 65536×1. LUT1..4 totals are 1844/1848/1852, ALU1336,
FF786, SPX9×8, DSP0. This is isolated synthesis evidence, not routed timing,
system-level resource fit, or physical-board validation.

Actual fetched OpenCV `color_lab.cpp` and W3C CSS Color 4 sources are recorded
with hashes and UTC access times in `references.json`. The Bruce Lindbloom
matrix page could not be fetched due to TLS failure; this failure is explicitly
recorded and is not presented as an accessed reference.

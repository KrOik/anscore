# RAW white balance / four-CFA gray-world AWB

`raw_white_balance.sv` is a real same-frame RAW8/10/12 white-balance core. It
captures the input in synchronous RAM, computes four gains in hardware from
qualified samples, then replays and corrects every original RAW pixel. The
default isolated profile is 32×24 RAW12. No host gain calculation, external
arithmetic IP, asynchronous pixel-memory read, or DSP is required.

## Numerical contract

The repository Bayer ABI is **0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR**. Packed planes
are **0 R, 1 Gr, 2 Gb, 3 B**, with plane 0 occupying the least-significant lane.
The plane index is raster parity `{y[0],x[0]} XOR cfg_pattern`; this deliberately
keeps the two green locations separate.

All start configuration is latched on `start_valid && start_ready`. The ROI is
inclusive `(x0,y0)..(x1,y1)` in image coordinates, and qualification is
`low <= raw <= high`. Only original captured samples are counted. Every
qualified sample contributes to its own plane's unsigned 32-bit `sum` and
`count`. Thresholds do not remove pixels from the output image.

Let `SG=sumGr+sumGb`, `CG=countGr+countGb`, and let `Sp,Cp` be a plane's
qualified sum/count. The reference mean is the **pooled green sample mean**
`SG/CG`, not `(meanGr+meanGb)/2`. In automatic mode:

```
gain[p] = clamp(round_half_up((SG * Cp * 4096) / (CG * Sp)), gain_min, gain_max)
corrected = round_half_up(raw * gain[plane] / 4096)
output = min(2^BITS - 1, corrected)
```

Q12 gain storage is unsigned 16 bits: 4096 is unity, 0 is legal when bounds
allow it, and 65535 is the maximum. The multiplication and restoring division
are performed by one shared 32-step unsigned multiplier and one 64-step divider.
Division uses `(numerator + floor(denominator/2))/denominator`, giving exact
positive round-half-up including odd divisors. Gr and Gb have independent
gains so their individual qualified means are moved toward the pooled target.

Manual mode uses the four latched `cfg_manual_gains` directly, with the same
Q12 output rounding/saturation and statistics collection. All manual gains must
already fall inside the supplied inclusive bounds; they are validated rather
than silently clipped. A manual frame remains valid if statistics are empty or
zero, since they are not used to divide. Automatic missing samples or a zero
sum is an explicit error, including thin images lacking one or more CFA planes.

## Interface and recovery

Parameters are `WIDTH=32`, `HEIGHT=24`, `BITS=12`. Width/height are 1..4096,
total pixels are at most 65536, and BITS is 8, 10, or 12. These are architectural
limits, not claims that every maximum geometry fits Tang on-chip memory.

* `cfg_auto`, `cfg_pattern`, four 16-bit ROI coordinates, `cfg_low/high`,
  16-bit `cfg_gain_min/max`, and packed 64-bit manual gains are sampled at start.
* Input is `s_data/s_valid/s_ready/s_sof/s_eol/s_last`; markers must denote exactly
  the first pixel, each line end, and the final pixel in a complete raster frame.
* Output is `m_data/m_valid/m_ready/m_sof/m_eol/m_last`, plus `m_saturated`.
  Saturation indicates the rounded value exceeded the maximum, not equality.
* `stats_sums` and `stats_counts` each expose four 32-bit lanes;
  `applied_gains` exposes four 16-bit lanes; `green_sum/count` expose SG/CG.
  Statistics are live during capture. They are final at DONE; applied gains are
  valid for the completed result only if `done_error==0`. Error results may
  contain partially computed gains and must not be consumed as successful data.
* `done_valid` is held until `done_ready` on an enabled edge. No new start or
  input is accepted until acknowledgment. A subsequent start clears statistics
  and error status. DONE and output payload remain stable across backpressure.

Transfers require `ce && valid && ready` at a rising edge. CE freezes state,
arithmetic, memory accesses and output, while active-low synchronous reset has
priority even when CE is zero. Reset discards the entire in-progress frame and
clears status; the next successful frame overwrites every pixel before replay.
There is no runtime abort pin or timeout. If a source stops mid-frame, reset is
the cancellation mechanism. All configuration fields may change after start
without affecting that frame.

Errors are `1` invalid configuration (ROI, threshold order, gain bounds, or
out-of-bounds manual gain), `2` malformed input markers, `3` absent qualified
plane/green samples, `4` zero denominator sum, `5` illegal internal state.
Error priority within a plane is missing samples before zero sum; planes are
checked R, Gr, Gb, B. A configuration error produces DONE without accepting a
pixel. Marker/statistical errors produce no output because full capture and all
gain calculations precede replay. Outputs already transferred before reset
belong to a discarded partial frame. There is no silent fallback to unity AWB.

Capture accepts one sample per enabled cycle. Gain computation costs 528 enabled
cycles for a healthy automatic frame. Serialized output has a 36-enabled-cycle
pixel interval without stalls; manual mode skips gain calculation. This is a
resource-oriented same-frame implementation, not a video-rate line streamer.

## Arithmetic bounds and resources

For N<=65536 and BITS<=12, even conservative bounds that ignore the smaller
physical CFA occupancy give `sum <= N*4095 < 2^28`, `count <= 2^16`,
`SG <= N*4095 < 2^28`, `CG <= 2^16`, and denominator `<2^44`.
The gain numerator before rounding is `<2^56`; adding half a denominator stays
`<2^57`. All intermediate products and divider state are 64 bits. Output raw
times the maximum gain plus 2048 is `<2^29`. No truncation occurs before rounding.

Isolated `synth_gowin -nodsp` + `check -assert` results:

| Profile | Conservative LUT-class | DSP | Raw RAM primitives | Conservative BRAM9 units |
|---|---:|---:|---|---:|
| 32×24 RAW12 default | 2652 | 0 | 1 SPX9 | 2 |
| 31×17 RAW10 | 2660 | 0 | 1 SPX9 | 2 |
| 8×6 RAW8 | 2680 | 0 | 6 RAM16SDP4 | 0 |

LUT-class includes LUT, ALU, MUX and **4 per RAM16SDP4**. BRAM9 accounting
conservatively charges two units per SPX9 instead of confusing raw primitive
count with physical 9-Kbit units. Figures are isolated synthesis, not routed
timing or whole-system fit. Each measured profile meets 15K LUT-class / 4 DSP.

## References and actual comparison

`fetch_references.py` downloads mature upstream source, records URL/SHA256 and
algorithm excerpts in `references.json`, and removes temporary downloads.

* Raspberry Pi libcamera `Awb::awbGrey` uses trimmed per-zone red/blue estimates,
  separate sorted sample lists and `G/(R+1)`, `G/(B+1)`, with green gain unity.
  It validates the gray-world gain direction, but it is **not** the same pooled
  four-plane statistic or a bit-exact reference for this module.
* Infinite-ISP `white_balance.py` applies CFA-dependent red/blue gains and clips
  RAW range; its automatic wrapper selects algorithms and clamps gains to >=1.
  This module intentionally permits attenuation, corrects Gr/Gb separately,
  defines half-up fixed-point rounding, and rejects missing samples explicitly.
* Infinite-ISP `gray_world.py` actually computes `meanG/meanR` and `meanG/meanB`.
  `test_reference.py` downloads and executes that **unmodified source**, then
  compares four real RTL frames under the common contract: full equal-population
  CFA cells with Gr=Gb, no gating, and Q12 quantization error <=0.5 gain LSB.
  This yields four patterns / 192 pixel comparisons. Unequal surviving green
  counts use our explicit pooled-mean Fraction oracle rather than an unsupported
  equivalence claim to an RGB algorithm. No upstream code is copied into RTL.

## Reproduce evidence

Run from repository root with Python/numpy and the local OSS CAD Suite:

```
python -B cores/system/common_scaffold/image/raw_white_balance/run_tests.py
python -B cores/system/common_scaffold/image/raw_white_balance/test_protocol.py
python -B cores/system/common_scaffold/image/raw_white_balance/test_numeric_limits.py
python -B cores/system/common_scaffold/image/raw_white_balance/test_reference.py
python -B cores/system/common_scaffold/image/raw_white_balance/synth_check.py
python -B cores/system/common_scaffold/image/raw_white_balance/freeze.py
```

The main suite uses independent `fractions.Fraction` arithmetic for exact gain,
statistics and every output/saturation/marker. It covers all four CFA patterns,
three RAW widths, odd/default/thin geometries, unequal population gating,
ROI boundaries, gain clipping, zero/manual gains, saturated outputs, invalid
configuration, absent samples, zero denominator, malformed markers, start-config
latching, random CE and output stalls, and DONE holding/recovery. Thin-image
automatic errors and successful manual output are both checked.

Protocol tests add nine CE-disabled resets across capture, multiply, divide,
RAM read/wait, output preparation, stalled output and DONE, ten clean recovery
frames (480 pixels), and a marker error after partial capture. Numeric-limit tests
reject seven illegal profiles and run the maximum supported 256×256 RAW12 frame
through real capture/statistics/hardware gain calculation and all 65536 outputs.
TemporaryDirectory removes netlists, simulator images and downloaded sources.
Compact JSON evidence and frozen source hashes remain. No JTAG, UART, existing
48-core acceptance scripts, or shared registry is touched. **Board acceptance has
not been performed for this new module.**

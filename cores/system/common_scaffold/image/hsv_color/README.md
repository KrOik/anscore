# RGB / HSV_FULL streaming converter

`rgb_hsv_full_stream.v` is an 8-bit-per-channel reusable bidirectional converter.
This is HSV_FULL, not the 0..179 hue representation. Its conventions follow
OpenCV: forward RGB→HSV quantizes hue over **256** levels; inverse HSV→RGB uses
**255** as one full turn, so inverse H=255 equals H=0. Consequently a round trip
is quantized and the two hue scales are intentionally asymmetric.

## Interface and framing

All signals are synchronous to `clk`. Active-high `rst` overrides `ce` and aborts
the current frame, including pending output. `WIDTH` and `HEIGHT` must be positive
and their product at most 65536. START is accepted on `start_valid && start_ready`
at a rising edge; it snapshots `cfg_inverse` (0 RGB→HSV, 1 HSV→RGB). Direction
changes while busy have no effect. Each frame consumes exactly WIDTH×HEIGHT
pixels, in row-major order. Bits 23:16 / 15:8 / 7:0 are R/G/B for RGB and H/S/V
for HSV. There is one output for every accepted input.

Input transfer requires `ce && s_valid && s_ready`, output transfer requires
`ce && m_valid && m_ready`. Output data, SOF/EOL and valid remain stable under
backpressure and while CE is zero. `m_valid` is intentionally visible during
CE=0; consumers must obey the CE-qualified transfer rule. Ready signals are
deasserted during CE=0. No additional pixel is accepted while processing the
previous pixel. Both frame data and its final output must be transferred before
the next START. `busy` covers frame acquisition, pending output, and unacknowledged completion.

`s_sof` must be asserted only on the first pixel; `s_eol` must identify each
final column. Incorrect markers set sticky `error`; they do not change the
fixed pixel count or arithmetic. Output markers are regenerated from geometry.
Consumers must discard the **whole frame**, including any previously emitted
prefix, if `error` is set. At final output transfer, `done_valid` becomes one and
is held until `ce && done_valid && done_ready`. This completion handshake returns
the core to idle and permits another START. Legacy `done` and `error` remain held
until accepted START or reset. `error_code` OR-accumulates bit0 missing SOF, bit1
extra SOF, bit2 missing EOL and bit3 extra EOL; 15 also indicates illegal internal
state. Early abort is supported by reset. Start/config requests while busy are
not accepted.

## Arithmetic

All divisions use integer nearest rounding, half upward. Forward V=max(R,G,B),
S=round(255×delta/V). Hue uses the usual six-sector numerator with R then G then
B tie priority, H=round(256×numerator/(6×delta)) modulo256. Achromatic pixels
produce H=S=0. Inverse uses sector/fraction from 6H/255, then the exact rational
intermediates V(255-S)/255, V(65025-Sf)/65025 and
V(65025-S(255-f))/65025 before sector permutation. H=255 explicitly wraps to red.

A single 24-bit restoring divider is shared across two forward or three inverse
divisions. All multiplications are explicit constant or shift-add logic. This
area-oriented implementation is not one pixel per clock; backpressure is part
of the contract. No frame RAM, vendor IP, or runtime external lookup table is
required. This is a general color conversion core, not an HDR or linear-light
transfer function.

## Reproducible evidence

Run from the repository root:

```powershell
python -B cores/system/common_scaffold/image/hsv_color/test_hsv_color.py
python -B cores/system/common_scaffold/image/hsv_color/synth_hsv_color.py
```

The test uses an independent Python integer oracle and actual OpenCV 5.0.0
`COLOR_RGB2HSV_FULL` / `COLOR_HSV2RGB_FULL`. Across 5308 pixels (random colors,
all gray levels, extrema, sector boundaries and hue wrap), RTL equals the integer
oracle exactly. OpenCV maximum differences are forward [1,1,0] (circular hue,
saturation,value), inverse [0,1,1] (R,G,B). These are measured differences, not
bit-exact OpenCV claims: OpenCV forward uses rounded 12-bit reciprocal tables,
while its inverse uses floating interpolation and platform-dependent rounding.
The source URL and downloaded-file hash are in `references.json`.

Additional tests cover 11 multiline frames / 66 pixels, four malformed-marker
patterns in each direction with new-START recovery, reset at six processing
phases while CE=0, output holding, ignored busy configuration, and four invalid
static geometries. Generated HDL, executables and synthesis working files are
automatically removed by `TemporaryDirectory`. Only small evidence JSON remains.

Isolated `synth_gowin` plus `check -assert` passes at 16×16, 31×33 and 65536×1.
LUT1..4 totals are 1035/1029/1033, ALU 682, registers 219, DSP0, RAM0.
These are isolated mappings; no place-and-route, board execution, timing closure
or combined system resource-fit claim is made by this directory.


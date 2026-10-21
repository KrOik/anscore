# Floyd–Steinberg grayscale error diffusion

`floyd_steinberg.sv` implements sequential Floyd–Steinberg quantization with
7/16,3/16,5/16,1/16 error propagation. This is error diffusion, distinct from
the existing Bayer4x4 ordered dither. Input and output both use ordinary raster
order. Optional internal serpentine processing reverses odd rows and mirrors
the diffusion stencil; a result frame buffer restores raster output order.

## Exact fixed-point definition

Parameters: BITS8..12, OUTPUT_BITS1..BITS, WIDTH/HEIGHT1..4096, total pixels
<=65536. Let `M=2^BITS-1`, `C=2^OUTPUT_BITS-1`. Error accumulators are signed
32-bit **Q4 intensity units**. For each pixel, in the selected processing order:

```
corrected = clamp(input*16 + accumulated_error_Q4, 0, M*16)
code = floor((corrected*C + M*8)/(M*16))
reconstructed = floor((code*M + floor(C/2))/C)
error_Q4 = corrected - reconstructed*16
contribution_Q4(weight) = sign(error_Q4) * floor((abs(error_Q4)*weight+8)/16)
```

The output code represents a uniformly spaced full-scale quantization level.
Code and reconstructed intensity use positive half-up rounding; reconstruction
maps code0 to0 and codeC toM exactly. Error propagation rounds each weighted
signed contribution independently to nearest Q4, ties away from zero. Corrected
input is clamped **before** quantization and error calculation. No extra error
buffer clipping is applied. The conservative32-bit error storage has ample
headroom for supported pixel depths.

For a left-to-right row, add the four contributions to:

| Neighbor | Weight |
| --- | ---: |
| `(x+1,y)` | 7/16 |
| `(x-1,y+1)` | 3/16 |
| `(x,y+1)` | 5/16 |
| `(x+1,y+1)` | 1/16 |

Right-to-left serpentine rows mirror x offsets. Contributions to neighbors
outside the frame are discarded, without renormalizing surviving weights.
Already consumed error locations are zeroed. Both error rows are explicitly
cleared before every frame, preventing cross-frame leakage. With OUTPUT_BITS
equal to BITS, all integer input samples pass through exactly and no error is
generated; this identity case is tested at8 and12 bits.

The rounding/clamping policy is explicit and is not claimed bit-identical to
Pillow's implementation-specific internal integer diffusion. No library golden
was substituted for this core's independent exact sequential oracle.

## Interface, memory and recovery

All transfers require `rst_n && ce && valid && ready` at the rising clock edge.
Reset is synchronous, overrides CE and aborts every phase. `cfg_serpentine` is
snapshotted on the first accepted input pixel; changes during partial capture,
processing, output and DONE affect no part of that frame.

Input uses `s_pixel/s_valid/s_ready`, SOF only on pixel zero and EOL on every
last-column pixel. Full-frame input capture precedes processing. A marker fault
immediately aborts capture and emits stable done_valid/done_error with no pixel
outputs for the aborted frame. Acknowledge with done_ready to retry from a new
SOF. A wrong SOF cannot silently restart a partially captured frame.

Processing uses synchronous frame RAM, a two-row synchronous error RAM with
sequential read/modify/write diffusion, and a synchronous result frame RAM.
Logical memory bits are `N*(2*BITS+OUTPUT_BITS) + 2*WIDTH*32`. Memory contents are
not reset; complete new capture, explicit row clear and complete result writes
prevent stale outputs after reset/reuse. There is one frame transaction, with
no simultaneous next-frame capture.

Output contains `m_pixel` reconstructed intensity, `m_code`, raster x/y and
SOF/EOL/LAST. All fields hold under output backpressure and CE pauses. Valid
remains asserted through CE pauses but transfers stop. After the final pixel,
done_valid holds with done_error zero until acknowledged. No new input is
accepted during processing, output or completion. Prior done_error clears on
the next first input pixel or reset.

A shared32-step restoring divider computes code and reconstruction in separate
passes, without a combinational divider. Multiplication by static constants
uses shift/add logic. Processing is serial, with64 division cycles per pixel
plus RAM/control cycles and neighbor updates; edge pixels skip out-of-bounds
neighbor transactions. Input can accept one pixel per enabled cycle; buffered
output-valid interval is three enabled cycles with immediate consumption.
This module does not claim full-resolution real-time video throughput.

## Verification and brightness measurements

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/error_diffusion/run_tests.py
python -B cores/system/common_scaffold/image/error_diffusion/synth.py
```

The independent Python oracle uses an entire2-D signed error array and sequential
integer updates, rather than copying the hardware two-row memory schedule.
198 frames /9438 output pixels over nine configurations pass. Coverage includes
8/10/12-bit input, output depths1/2/3/4 and full-depth identity, both scan modes,
low/full gradients, constant levels, all black/white, checkerboards, random
frames, thin/single-pixel images, repeated frames, configuration snapshot,
CE/output/DONE stalls, marker faults and recovery, and CE-low reset during
capture, row clear, division, diffusion and pending output. Five invalid static
parameter cases are rejected.

`brightness_measurements.json` records actual input/output frame means for all
198 cases. Measured maximum absolute normalized frame-mean errors:

| Configuration | Fraction of full scale |
| --- | ---: |
| 9x7,B8,O1 | 0.05658263 |
| 17x13,B8,O2 | 0.00935143 |
| 7x5,B10,O4 | 0.00430108 |
| 5x7,B12,O3 | 0.01140764 |
| 1x11,B12,O1 | 0.24981685 |
| 11x1,B8,O1 | 0.24705882 |
| 1x1,B10,O2 | 0.16617791 |
| Full-depth identity cases | 0 |

Across the fixture set, mean absolute normalized frame-mean error is0.02164658.
Discarded border contributions and corrected-input clipping can bias brightness,
especially in thin images with very few available neighbors. Error diffusion
therefore does not guarantee exact frame-mean conservation. These are numerical
measurements, not visual quality or perceptual acceptance.

Isolated Gowin synth/CHECK at9x7 passes:

| Bits / output bits | LUT1..4 | FF | RAM16SDP4 | DSP |
| --- | ---: | ---: | ---: | ---: |
| 8 / 1 | 1378 | 255 | 36 | 0 |
| 12 / 4 | 1757 | 276 | 44 | 0 |

These small instances use distributed RAM with synchronous behavior. No
place/route, timing closure or board acceptance is claimed. Testbenches,
vectors and simulation/synthesis intermediates use automatically cleaned
temporary directories; compact evidence and logs remain.

## Public mathematical reference

Successfully accessed2026-10-19:
[Floyd–Steinberg dithering](https://en.wikipedia.org/wiki/Floyd%E2%80%93Steinberg_dithering).
The source describes the7/16,3/16,5/16,1/16 stencil and mirrored serpentine
processing. Only the public mathematical algorithm informed the independently
written RTL and oracle; no third-party source code was copied. `reference.json`
records the exact URL, access time and fetched-content SHA256.

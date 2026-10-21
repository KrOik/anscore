# Dense single-scale Lucas–Kanade optical flow

`dense_lucas_kanade.sv` is a synthesizable two-frame, local least-squares optical
flow engine. It computes one vector per image coordinate, including explicit
invalid records. It implements a **single linearization at one scale**, with no
iteration, pyramids, motion warping, or hidden host calculation. This is useful
for small displacements and constrained resource experiments. It does not make
general large-motion, occlusion, photometric-invariance or real-time claims.

## Exact arithmetic contract

Input is a paired raster stream: `s_prev` and `s_curr` are unsigned same-location
pixels in the preceding and current frames. A transfer writes both images into
separate synchronous-read memories. After the full pair is captured, every
interior output uses a centered WINDOW x WINDOW neighborhood (WINDOW=3 or 5).
For each sample location in that neighborhood:

```
Ix = P(x+1,y) - P(x-1,y)
Iy = P(x,y+1) - P(x,y-1)
It = 2 * (C(x,y) - P(x,y))
A = sum(Ix*Ix); B = sum(Ix*Iy); Cn = sum(Iy*Iy)
D = sum(Ix*It); E = sum(Iy*It)
det = A*Cn - B*B
u = (B*E - Cn*D) / det
v = (B*D - A*E) / det
```

The factor two in It matches the omitted division by two in the spatial
central differences. A positive u means motion toward increasing x, positive v
toward increasing y. All sums/products are exact signed integers. A shared
serial restoring divider calculates `sign(num)*floor((abs(num)<<FRAC)/det)`.
`m_u,m_v` are signed OUT_BITS-wide QFRAC values in pixels, truncated toward zero.

`texture_threshold` is a **runtime input**, sampled with the
first accepted pixel of the frame pair. A vector is valid only if det>0 and
det>threshold. This threshold is in raw determinant units (fourth power of pixel
intensity, with the gradient/window factors); it is not OpenCV's normalized
minimum-eigenvalue threshold. If either quotient exceeds the signed output
range, both outputs become zero and `m_flow_valid=0`, without silently wrapping.
Out-of-range windows, zero texture and one-dimensional aperture cases similarly
emit a zero invalid vector. The border margin is WINDOW/2+1 on all sides,
because the spatial gradient needs another pixel outside the window. There is
no border extension. Small images with no interior emit all invalid records.

## Interface, reset and framing

Parameters: WIDTH/HEIGHT=1..4096, product <=65536; BITS=8..12; WINDOW=3 or 5;
FRAC=0..16; OUT_BITS=FRAC+2..32. Default 16x16, BITS8, WINDOW3, FRAC8, OUT_BITS24.
The output precision/range can be chosen independently of input bit depth.

Transfers require `rst_n && ce && valid && ready`. Reset is synchronous active
low and overrides CE. Do not hold/count transfers during reset even if ready is
combinationally high. s_sof must be true exactly at the first coordinate, s_eol
exactly at each last-column coordinate. A malformed marker aborts capture,
pulses done with error_code=1, and permits a new complete pair from fresh SOF.
All pixels of the new pair overwrite old RAM contents before processing; RAM
does not need reset clearing. Reserved illegal-state recovery reports error 2.
A legal first pixel clears the previous error.

busy covers partial capture, computation and output. s_ready is high only in
capture; the design does not overlap different frame pairs. Output m_valid
qualifies a record, m_flow_valid qualifies its vector. `m_sof,m_eol` describe all
records including invalid borders. Output fields remain stable until transfer,
including under CE pauses and m_ready backpressure. done pulses for one enabled
cycle after the final output transfer (or capture abort). Reset immediately
aborts pending capture, reads, multiplications, divisions and held output.

Input II is one enabled cycle. An interior pixel reads five locations with
three enabled edges per synchronous read, then spends five shared multiply
edges per window sample. Six more shared multiply edges form determinant and
numerators. Let `QW=4*BITS+15+FRAC`. A valid interior record takes
`20*WINDOW*WINDOW + 10 + 2*QW` enabled edges after entering PIX until m_valid is
asserted, followed by at least one transfer edge. A threshold-invalid interior
record takes `20*WINDOW*WINDOW+8` edges. Border records take one edge to assert
m_valid. Output backpressure and CE extend wall-clock time. This serial design
prioritizes bounded logic rather than pixel-rate throughput.

## Width and storage bounds

Let L=2^BITS-1. Spatial gradients have magnitude <=L; temporal gradient <=2L.
At most 25 samples contribute. Therefore |A|,|B|,|Cn| <=25 L² <2^(2BITS+5),
and |D|,|E| <=50 L² <2^(2BITS+6). Signed normal sums use NW=2BITS+7 bits,
whose positive capacity exceeds these bounds. The shared multiplier has two
NW-bit operands and a signed 2NW-bit product. Extended products/subtractions
use DW=2NW+1=4BITS+15 bits; these cover determinant and both numerators without
overflow. In particular a numerator's magnitude is <2^(4BITS+12), below DW's
signed capacity. The numerator shifted by FRAC occupies QW=DW+FRAC bits and is
divided using a DW+1-bit unsigned remainder. Negative numerators are converted
to magnitude before shifting; division signs and signed minimum values are
handled explicitly. No floating-point hardware is used.

The two memories contain 2*WIDTH*HEIGHT*BITS data bits, with true synchronous
read ports. Maximum logical capacity is supported by the address/counter
widths; **large geometries may exceed a particular FPGA's BRAM budget**. This
is not a claim that two 65536x12 images fit Tang 20K. No clock-domain crossing
or external DRAM controller is included.

## Validation and references

```powershell
python cores/system/common_scaffold/image/optical_flow/test_optical_flow.py
python cores/system/common_scaffold/image/optical_flow/synth.py
```

Python arbitrary-precision formulas independently calculate every expected
output; the simulation compares every RTL vector, validity flag and marker.
Cases include flat fields, one-dimensional aperture, static texture, exact
first-order displacement, actual image translations, random independent pairs,
fullscale discontinuities, 12-bit/5x5 accumulation, output overflow rejection,
threshold snapshot, multiple frames, CE/gaps/backpressure and malformed markers.
Tests explicitly reset while reaching interior ADDR, MUL, DIVU and DIVV states,
plus partial capture and held output, with CE=0. Invalid-parameter checks reject
nine unsupported configurations. Temporary testbenches, input vectors and
binaries are removed by TemporaryDirectory; compact evidence and synthesis logs
remain.

Current regression passes **161 frame pairs / 15069 pixel records**, including
4187 valid vectors and 13 overflow-rejected vectors, plus nine invalid-parameter
cases. Fullscale tests reach a normal sum magnitude 419225625 and determinant
140600099725312500, checking values well beyond 32 bits against Python integers.
Standalone `synth_gowin -noalu -nodsp` reports CHECK zero problems:

| Configuration, 16x16 | LUT1..4 | FF | MUX5 | BRAM | DSP |
|---|---:|---:|---:|---:|---:|
| BITS8 WINDOW3 | 3117 | 658 | 138 | 2 DPX9B | 0 |
| BITS12 WINDOW5 | 4845 | 822 | 171 | 2 DPX9B | 0 |

These isolated logic estimates meet the requested 15K LUT / 4 DSP bounds for
the two reported configurations; they are not integrated-top or routed metrics.

The translation-quality measurements in evidence.json are calculated by the
independent Python oracle **and** validated by bit-for-bit RTL equality for the
same full images. Eight smooth-texture ±1-pixel x/y shifts at 16x16, WINDOW3/5
have median component error below 0.11 pixel. This describes these fixtures,
not a universal accuracy bound.

Consulted and fetched public references (hashes in reference.json):

- [OpenCV optical flow tutorial source](https://raw.githubusercontent.com/opencv/opencv/4.x/doc/py_tutorials/py_video/py_lucas_kanade/py_lucas_kanade.markdown): brightness constraint and local Lucas–Kanade least squares. The rendered documentation returned HTTP403; its actual markdown source was fetched instead.
- [OpenCV pyramidal LK source](https://raw.githubusercontent.com/opencv/opencv/4.x/modules/video/src/lkpyramid.cpp): comparison of engineering scope. Its pyramids, iterations, interpolation and derivative rules differ; this core is not bit-compatible with calcOpticalFlowPyrLK.

Independent RTL implementation. No board programming, routed timing validation
or physical optical-flow acceptance has been performed for this core.

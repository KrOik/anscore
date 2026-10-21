# Sobel / Scharr Stream gradients

Complete isolated 3×3 Sobel/Scharr Gx/Gy, exact integer Euclidean magnitude or
explicit L1 magnitude, bounded-error eight-direction quantization, and inclusive
magnitude threshold. Input is unsigned 8/10-bit raster; compile-time WIDTH/HEIGHT,
PAD_MODE=0 ZERO or 1 REPLICATE. Output dimensions equal input dimensions, including
1×1 and widths/heights below three. The shared row-buffered window is read-only.

## Arithmetic and coordinates

Sobel Gx kernel is `[[-1,0,1],[-2,0,2],[-1,0,1]]`; Scharr uses 3/10/3 instead
of 1/2/1. Gy is the transpose. Image x points right and y points down, so positive
direction angles run clockwise on the displayed raster. No derivative normalization
is applied: Sobel's axis maximum is `4*(2^BITS−1)`, Scharr's is `16*(2^BITS−1)`.
All intermediate derivative sums retain their full integer range.

Let `G=BITS+5`. Gx/Gy use signed G-bit two's complement (13/15 bits). Magnitude
uses unsigned G bits. The sum of squares uses 2*G bits; exact floor square root is
computed by restoring two radicand bits per cycle. It satisfies
`mag^2 <= Gx^2+Gy^2 < (mag+1)^2`. Euclidean floor error is [0,1) relative to
floating `hypot`. L1 instead returns exactly `abs(Gx)+abs(Gy)` and is **not** an
exact Euclidean magnitude; its ratio is between 1 and sqrt(2) for nonzero vectors.
Threshold comparisons use whichever mode was selected. No saturation or rounding
is needed for derivatives/L1; the integer square root deliberately floors.

Direction is three bits: 0 east, 1 southeast, 2 south, 3 southwest, 4 west,
5 northwest, 6 north, 7 northeast. The first quadrant is split by the exact integer
comparisons `128*abs(Gy) < 53*abs(Gx)` and its transpose; equality selects the
diagonal. Remaining quadrants are reconstructed from derivative signs. Therefore
the worst angular error is `45°−atan(53/128) < 22.52°`, including ratio quantization.
This is a bounded eight-sector approximation, not a fine-angle atan/CORDIC result.
Zero gradient outputs direction zero and direction_valid=0. The edge flag is
`magnitude >= threshold`; in particular zero magnitude passes threshold zero.

Output tdata is packed least-significant field first:

| Bits | Field |
|---|---|
| G−1:0 | signed Gx |
| 2G−1:G | signed Gy |
| 3G−1:2G | unsigned magnitude |
| 3G+2:3G | direction |
| 3G+3 | direction_valid |
| 3G+4 | threshold edge flag |

Output SOF/EOL remain separate Stream sidebands bound to the result. Software
must sign-extend Gx/Gy when decoding the packed word.

## Configuration, reset and rate

`cfg_valid/cfg_ready` transfers `cfg_scharr` (0 Sobel / 1 Scharr), `cfg_l1`
(0 Euclidean floor / 1 L1), unsigned G-bit threshold and two reserved bits.
Reserved bits must be zero; otherwise cfg_error pulses and prior settings remain
active. Legal updates pulse cfg_done. Defaults are Sobel, Euclidean, threshold 0.
Config is accepted only when an entire frame has drained and takes priority over
a new frame on the same edge. A held next config during busy does not stop the
current frame. No mixed operator/threshold state can reach a late result.

`busy` spans first input through final output acceptance. rst_n is low-active
synchronous and discards all in-flight window/square-root/output state. Row RAM
is not cleared; window validity suppresses old data. Valid/data/markers hold under
backpressure. `marker_error` is sticky until reset and does not resynchronize an
incorrect raster. WIDTH must be positive and <=4096 (the shared window default),
HEIGHT positive; dimensions and border mode are static.

The arithmetic service latency and II are both **2 clocks in L1**, and
**G+2 clocks in Euclidean mode** (15 at 8-bit, 17 at 10-bit). Two parallel squares
feed an iterative square root. Adjacent no-stall outputs within a row meet this
II, checked in simulation. First-result latency is
`WIDTH*(1+min(1,HEIGHT−1)) + 2*(WIDTH+2) + 6 + service_latency` cycles.
Source row capture/replay and frame drain further limit average rate; there is
no whole-frame II=1 claim. Backpressure stretches wall-clock result time and
blocks a new arithmetic transaction until the current output is accepted.

## Reproduce / evidence

```sh
python cores/signal_processing/dsp_isp_library/isp/gradient/test_gradient.py
python cores/signal_processing/dsp_isp_library/isp/gradient/synth_gradient.py
```

The independent model performs direct 2D kernel accumulation, Python integer
isqrt, floating hypot and atan2. Tests compare every packed field and marker;
they also check the Euclidean floor error and angular error against float values.
Ten configurations cover both borders, 1×1/2×2/normal images, 8/10 bits and every
operator/magnitude combination. Patterns include zero, maximum, horizontal and
vertical steps, checkerboard, impulse, ramp and seeded random images for both
operators. Each case processes 51 frames across three reset epochs, including a
full-frame replay after a rejected configuration to prove old settings survive.

Tests include source gaps, random/long stalls, held output reset, queued next-frame
configuration, exact arithmetic latency, row II, first-output latency, malformed
markers, four unsupported static parameters and forty data/order/count/sideband
negative runs. Every run preserves source/model/test snapshots and hashes. The
initial development order-mutation run swapped equal singleton results and could
not demonstrate rejection; it remains preserved. The corrected test substitutes
a distinct final-frame result, without changing DUT or expected numeric values.

Final simulation evidence is `evidence/sim_20260925_033606_099677/`: all ten cases,
510 frames, forty negative runs and four illegal static parameters PASS. Observed
maximum angular error was 22.455317° (analytic bound 22.507389°); maximum Euclidean
floor error was 0.998645, below one magnitude LSB. No latch or width warning occurred
in synthesis; horizontal-history registers and ABC combinational-network notes
are expected.

## Isolated Gowin synthesis

Evidence: `evidence/synth_20260925_033507_435178/`, real
`synth_gowin -noalu -family gw2a`, WIDTH=32 and HEIGHT=24. Complete runtime-selectable
core plus window; counts exclude pads/constants and list muxes separately.

| Bits | Border | LUT1–4 | MUX2_LUT5 | FF | BSRAM | DSP |
|---|---|---:|---:|---:|---:|---:|
| 8 | ZERO | 1026 | 169 | 370 | 4 | 2 MULT18X18 |
| 8 | REPLICATE | 1033 | 171 | 369 | 4 | 2 MULT18X18 |
| 10 | ZERO | 1203 | 208 | 422 | 4 | 2 MULT18X18 |
| 10 | REPLICATE | 1200 | 210 | 421 | 4 | 2 MULT18X18 |

The script enforces <=4 Gowin DSP-class cells. Three SPX9 banks and one DPX9B
cache map synchronously. These are mapped resources, not routed timing or physical
acceptance. P&R, 27 MHz timing, board data injection/reprogramming and production
integration remain pending. The repository's active inferred-memory silicon
investigation also applies here. No hardware or shared file was modified.

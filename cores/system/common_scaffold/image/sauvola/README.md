# Integer Sauvola adaptive binarization

`sauvola_frame` consumes a grayscale frame and emits one threshold, foreground
bit, integer mean and standard deviation per input pixel. It adds population
variance based Sauvola thresholding; existing repository adaptive kernels use
mean-C or Gaussian mean-C. The older Harris feature core remains untouched.

## Exact arithmetic and border contract

Static parameters: BITS 8–12; WIDTH/HEIGHT 1–4096; RADIUS 1–7 (odd square
window side 3–15); K_Q8 0–256; R 1–(2^BITS-1), default 2^(BITS-1).
Each centered window uses replicate extension at actual frame borders,
including single-row/column images and windows larger than the frame.
Let N be the full window area, S the sum and Q the sum of squared intensities:

```
mean = floor(S/N)
variance = floor((N*Q - S*S)/(N*N))
stddev = floor(sqrt(variance))
threshold = floor(mean*((256-K_Q8)*R + K_Q8*stddev)/(256*R))
binary = center_pixel > threshold
```

The variance uses the exact rational population mean before quantization,
not `floor(Q/N)-floor(S/N)^2`. Floor of sqrt(floor(variance)) equals floor of
the true population standard deviation. The mean and standard deviation
outputs are BITS unsigned; threshold is 2*BITS unsigned, deliberately not
clipped to pixel range when small R gives a large threshold. The binary
comparison is strict. K=0 gives the floored local-mean threshold.

This is a quantized Sauvola variant. It is not bit-compatible with floating
scikit-image or OpenCV. Our default R is the integer power of two, whereas
scikit-image's dtype-based default is half of its full range (127.5 for uint8).
For comparison use the same explicit R, K, neighborhood and border policy.
Writing k=K_Q8/256 and D=2^BITS-1, true real-valued Sauvola threshold T obeys
`0 <= T-threshold < 2-k+3*k*D/(2*R)`: floor mean/stddev/final threshold each
reduce the result, population stddev <= D/2, and mean <= D. At ordinary R,
fixture maximum threshold error is 2.018059 intensity units. The deliberate
R=1 stress case reaches 143.112261. One foreground decision differs from the
real-valued reference over 1485 tested pixels; exact integer RTL agreement is
1485/1485. Error is parameter dependent; no universal float equivalence claim.

## Protocol and errors

Every transfer requires `ce && valid && ready`. Synchronous active-high reset
overrides CE and cancels capture, processing or pending output. SOF must mark
only the first pixel and EOL the final pixel of every row. The fixed input
length is always WIDTH*HEIGHT. Marker errors latch, but processing and all
outputs continue; at DONE the consumer must discard the entire erroneous
frame. This is not a fail-stop/abort policy. Missing pixels must be supplied
or reset; marker flags cannot infer lost transfers. Next frame's first
accepted pixel clears errors. Arithmetic_error flags impossible negative
variance numerator; legal bounds exclude this event.

Output x/y are raster coordinates. SOF/EOL/LAST accompany the corresponding
valid sample. Data/markers stay stable through CE pauses and output stalls.
DONE and errors remain held until done_ready. Input is stalled while processing,
output or DONE is pending. busy is asserted for partial capture or any later
state. Ignore output data outside valid; memory read data need not reset.

## Hardware and bounds

The only image storage is WIDTH*HEIGHT*BITS synchronous RAM; no array reset,
asynchronous frame reads, host precomputed thresholds or hardware real values
are used. One shift-add multiplier and one restoring divider are reused.
The square root consumes two radicand bits per cycle. Window scanning trades
throughput for size: about N*(MW+4)+6*MW+BITS+9 enabled cycles per output,
MW=2*BITS+18, with ready continuously asserted. Full-frame capture precedes
processing. This is not a video-rate streaming-throughput claim.

For N<=225 and D<2^BITS: S<=N*D<2^(BITS+8), Q<=N*D^2<2^(2*BITS+8),
N*Q and S^2 <2^(2*BITS+16). S uses BITS+ceil(log2(N+1)) bits and Q twice
BITS plus that log width. Shared arithmetic MW=2*BITS+18 covers all products,
including threshold numerator <256*D^2 and all divisors. Cauchy–Schwarz gives
N*Q>=S^2; variance <=D^2/4; stddev fits BITS; threshold <=D^2 fits 2*BITS.
Thus there is no intended saturation or truncation of legal arithmetic.
Legal maximum frame geometries can exceed a device's RAM budget.

## Validation

```
python -B cores/system/common_scaffold/image/sauvola/test_sauvola.py
python -B cores/system/common_scaffold/image/sauvola/synth_sauvola.py
```

88 frames/1485 pixels PASS over eight configurations, using independent
Python big-integer deviations and math.isqrt, with a separate math.fsum/sqrt
real-formula audit and analytical error bound. Cases include 8/10/12 bits,
flat black/white/midgray, ramps, corner, checkerboard, illumination/text pattern,
random noise, thin line, blank recovery, single rows/columns, radius7, K0/K256,
R1, SOF/EOL errors, CE/input gaps/backpressure, held DONE and reset with CE low
during capture, active arithmetic and stalled output. Nine illegal parameter sets are rejected.

Isolated synth_gowin and CHECK PASS:

| Profile | LUT1–4 | LUT5 mux | ALU | FF | RAM primitive | DSP |
|---|---:|---:|---:|---:|---:|---:|
| B8,32x32,radius1,K51,R128 | 554 | 25 | 274 | 468 | 1 DPX9B | 0 |
| B12,64x48,radius7,K256,R2048 | 687 | 30 | 333 | 599 | 3 DPB | 0 |

No integrated budget, timing closure, physical board or application acceptance
is claimed. Only small JSON statistics are retained; generated test/synthesis
files use TemporaryDirectory and are removed after execution.

## Public design reference

Successfully accessed 2026-10-19:
https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/filters/thresholding.py
(`threshold_sauvola` documentation). It states
`T=m*(1+k*(s/R-1))` and strict image>T, with source paper Sauvola and Pietikainen,
Adaptive document image binarization, Pattern Recognition 33(2), 225–236 (2000),
DOI 10.1016/S0031-3203(99)00055-2. Only the mathematical specification was
consulted; no implementation code was copied. Our RTL and integer oracle were
written independently and use explicit quantization/border rules above.

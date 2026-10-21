# Integer 2D FFT phase correlation

`phase_correlation_frame.v` estimates one circular integer translation between
two 8-bit grayscale frames. It actually computes two 2D FFTs, complex
`FFT(A)*conj(FFT(B))`, true Euclidean magnitude normalization, a 2D inverse FFT,
and a real-correlation peak. There is no SAD, block matching, or spatial
correlation substitute. Supported square sizes are 8×8, 16×16 and 32×32.

For `B=roll(A,dy,dx)`, outputs are the displacement **to align B to A**:
`m_dx=-dx`, `m_dy=-dy`, reduced into [-SIDE/2,SIDE/2-1]. The exact half-period
is represented negatively. OpenCV `phaseCorrelate(A,B)` reports the opposite
direction and can represent the half-period positively; tests normalize this
convention explicitly. There is no subpixel estimator or rotation/scale model.

## Frame interface

START is `ce && start_valid && start_ready` and snapshots `cfg_remove_dc`.
Each accepted `s_valid && s_ready && ce` supplies corresponding `s_a` and `s_b`
pixels at one raster coordinate. Exactly SIDE² pairs are required. SOF must
identify only the first pair and EOL every final column. No new frame is
accepted during processing or before its output and completion are consumed.

One result is emitted with `m_valid`: signed 7-bit dx/dy, signed 32-bit Q20
`m_peak`, 16-bit `m_valid_bins`, and `m_invalid`. Transfer is
`ce && m_valid && m_ready`. Payload and valid remain held under backpressure
and CE=0; consumers must qualify valid with CE. Ready signals are low while
CE=0. After result transfer, `done_valid` is held until
`ce && done_valid && done_ready`. Busy includes pending result and completion.
The next accepted START clears previous errors. Requests while busy are ignored.

`rst` is active-high synchronous, overrides CE, and cancels acquisition,
arithmetic, pending result, or completion. Coefficient RAM is not reset;
complete new input acquisition and complete cross-spectrum generation overwrite
every location before subsequent reads, preventing stale-frame reuse.

Error-code bits are sticky within a frame:

- bit0 missing SOF; bit1 extra SOF; bit2 missing EOL; bit3 extra EOL;
- bit4 insufficient texture / ambiguous or nonpositive peak;
- bit5 illegal internal state.

Malformed markers retain the fixed acquisition length, followed by a result
with `m_invalid=1` and held errored completion. Discard that whole estimate.
Reset provides early cancellation. Invalid static SIDE parameters terminate
simulation at time zero.

## Fourier and numerical implementation

Three synchronous complex RAM banks store A, B and normalized crosspower.
Each coefficient is signed 24-bit real plus signed 24-bit imaginary. Two true
read/write ports per bank share identical physical port addresses; there are
no asynchronous coefficient reads or giant resettable state arrays.

Capture bit-reverses both coordinate indices. In-place radix-2 DIT butterflies
then transform all rows and columns. Forward A and B each scale by 1/2 per
stage, giving overall 1/SIDE² normalization. Crosspower is written into the
third RAM in doubly bit-reversed order before the row/column inverse transform.
Inverse butterflies also scale per stage, producing the normal IFFT factor
1/SIDE². Twiddles are signed Q15 with 17 bits, generated from the 32-point roots
of unity; smaller transforms use the corresponding subset. `twiddle.mem` must
be delivered with the RTL, or override `TWIDDLE_FILE` with its absolute path.

Input samples have 12 fractional bits. Each butterfly uses one shared signed
32×32 serial shift-add multiplier and signed 64-bit intermediates; rounded
twiddle products and per-stage division keep the 24-bit state bounded.
For each frequency, the full complex conjugate product is rounded right by 12
bits into signed 32-bit R and I. A 64-bit squared magnitude is computed as
`R*R+I*I`. A 32-step restoring integer square root computes
`floor(sqrt(R*R+I*I))`; two serial 64/32 divisions generate Q20 normalized real
and imaginary coefficients. This is genuine complex magnitude normalization,
not an L1, max-component, or sign-only approximation.

Zero-magnitude bins contribute zero; `cfg_remove_dc=1` also sets the DC bin to
zero. `m_valid_bins` counts the remaining nonzero normalized bins. The peak
search uses the largest real IFFT value, row-major first on ties. Fewer than
three nonzero bins, a nonunique maximum, or a nonpositive maximum produces
`m_invalid=1`. Constant, zero and checkerboard inputs explicitly exercise this
path. A unique positive peak is not proof that unrelated images match;
applications must judge peak strength and image content. Near-tie confidence
or statistical match rejection is not implemented.

Arithmetic rounds nearest with halfway values away from zero, except unsigned
normalization division which rounds upward on a halfway value. Right-shifting
the crossproduct and flooring its square-root denominator introduce bounded
fixed-point approximation. `m_peak/2^20` is an approximate normalized real
correlation peak, not OpenCV's 5×5 centroid response statistic. With DC removed,
even ideal equal random frames have a peak near 1-1/SIDE² rather than 1.

There is no automatic Hann window, zero padding, or border extrapolation:
translations are periodic across the frame boundaries. For ordinary cropped
scenes with exposed borders, the circular model can be a poor match. This is
an area-oriented serial engine with substantial frame latency, not a video-rate
one-pixel-per-clock FFT pipeline.

## Reproduction and evidence

From the repository root:

```powershell
python -B cores/system/common_scaffold/image/phase_correlation/run_tests.py
python -B cores/system/common_scaffold/image/phase_correlation/synth_phase_correlation.py
```

The exact integer oracle recursively evaluates FFTs, independent of the RTL's
address generator and iterative stage controller. Actual streamed outputs are
checked for exact dx, dy, peak, bin count, invalid flag and error code. Actual
NumPy complex `fft2/ifft2` and OpenCV 5.0.0 `phaseCorrelate` calls independently
check all unambiguous translation fixtures. These include zero shift, mixed
positive/negative shifts, half-period wrapping, random textures, and a shifted
frame with gain×2 plus offset40. OpenCV displacement errors must be below
1e-5 after sign/wrap conversion; integer and NumPy peak locations must agree.

The main suite comprises 20 frames / 3584 input pairs across all supported
sizes, including DC on/off constant/zero/periodic inputs and all four marker
error patterns followed by recovery. Every eleventh arithmetic waiting cycle
pauses CE; output and completion also exercise explicit CE=0 and backpressure.
Additional tests reset at 10 phases (including square root, division, inverse
FFT and held completion), then run 10 healthy recovery frames; six unsupported
static sizes are rejected. Small evidence JSON is retained; generated
testbenches, simulators and working directories are automatically removed.

Full isolated Gowin mapping includes the FFTs, square root, divider and all
RAM banks. At SIDE 8/16/32, LUT1..4 counts are 2210/2235/2250, ALU counts
1617/1619/1622, FF counts 1375/1385/1395, DPX9B×9, DSP0. `check -assert`
passes. This is not routed timing closure, combined system fit, or board proof.

The first synthesis attempt used different read/write address mux nets, which
prevented BRAM port merging and caused excessive register expansion. That
attempt was stopped; the revised shared physical-port address structure maps
all three coefficient banks to actual DPX9B memory. All final simulation and
synthesis evidence is bound to the revised RTL hash.

`references.json` records actual downloaded OpenCV `phasecorr.cpp`, NumPy FFT
documentation/source, and scikit-image phase correlation source with hashes
and UTC times. These provide public examples of conjugate crossproducts,
Euclidean normalization, inverse FFT and peak interpretation. The system proxy
initially caused TLS failures; direct access succeeded. Reference fetching is
optional (`generate_tables.py --fetch`, with `--proxy` only when needed).

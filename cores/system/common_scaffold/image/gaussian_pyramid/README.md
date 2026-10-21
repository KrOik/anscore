# Multi-level Gaussian image pyramid

`img_gaussian_pyramid_frame.sv` generates LEVELS successive Gaussian
downsampling levels. Level zero is the first reduced image, not the input.
Each level uses the separable kernel [1,4,6,4,1] outer product, normalization
256, round-half-up `(sum+128)>>8`, then samples at source (2*x,2*y).
Dimensions become ceil(width/2), ceil(height/2) on every level.
REFLECT_101 border extension matches OpenCV pyrDown default behavior.
A dimension of one repeats its sole coordinate. Once 1x1 is reached,
remaining levels each contain one pixel. No intermediate rounding occurs
within the 25-tap convolution; each completed level is quantized to BITS.

BITS=8..16, positive WIDTH/HEIGHT<=4096, WIDTH*HEIGHT<=65536 and LEVELS=1..4
are static parameters. Input s_data/s_valid/s_ready carries one grayscale
raster with s_sof on the first sample and s_eol on every row's last sample.
Capture completes before output starts. Output m_data/m_level uses
m_valid/m_ready, m_sof at each level's first sample and m_eol at every
level row end. Levels are emitted in increasing order, each in raster order.
There is no configuration transaction or dynamic geometry.

Every handshake requires ce && valid && ready. Outputs including level and
markers hold while stalled. done_valid is held after the final level until
done_ready is accepted. frame_error reports malformed input markers; such
a frame produces no output levels. Discard the rest of malformed input,
acknowledge done, then start a fresh frame. Synchronous active-low reset
aborts the current transaction. Pixel RAM need not be reset because a valid
input frame fully overwrites the source before it is read.

Two synchronous ping-pong arrays each reserve WIDTH*HEIGHT*BITS bits.
No external memory is required. A reduced pixel uses 25 serial synchronous
reads and accumulation steps, a store cycle, and an output transfer
(52 enabled cycles without stalls). Only after all output pixels of a
level are accepted does the next level begin. This implementation favors
small arithmetic area over throughput; it has no continuous-video-rate
or qualified clock claim. It does not compute Laplacian residuals,
optical flow, feature descriptors or a full detection pipeline.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/gaussian_pyramid/run_tests.py
python -B cores/system/common_scaffold/image/gaussian_pyramid/synth.py
```

Independent integer convolution regression: 48 frames / 1032 output pixels,
eight profiles, 1..4 levels, 8/10/16-bit data, random/zero/max/impulse/ramp/edge
patterns. Covers odd sizes up to 17x13, reflection on 2x2, thin/1x1 images,
level/row/frame markers, random CE/backpressure, bad-frame recovery without
reset, and reset while waiting for a result. Installed OpenCV 5.0.0 also
passes 150 per-level exact numerical cross-checks (8-bit and uint16 paths).
OpenCV/NumPy are optional; per-profile external check counts are recorded.
Temporary vectors/executables are removed. Functional evidence:
`../../evidence/gaussian_pyramid_20261018T191814Z_ebf7ebfa`.

Default 16x16/8-bit/3-level Gowin synthesis (-noalu -nodsp): 824 LUT1..4,
104 MUX5, 86 FF, 64 RAM16SDP4 distributed-memory primitives, no DSP or
block RAM; check -assert PASS. Mapping depends on geometry.
Evidence: `../../evidence/gaussian_pyramid_synth_20261018T191746Z_4596cb61`.
No board acceptance, timing signoff or large-resolution performance claim.

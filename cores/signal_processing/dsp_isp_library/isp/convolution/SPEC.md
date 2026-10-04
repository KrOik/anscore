# Convolution specification

Input/output: unsigned 8/10-bit raster Stream, WIDTH×HEIGHT, SOF/EOL. K=3/5;
ZERO or REPLICATE padding is a compile-time PAD_MODE 0/1. This implements true
convolution: coefficient lane `ky*K+kx` multiplies the pixel at
`(y-(ky-K/2), x-(kx-K/2))`, not correlation. Kernel coefficients are signed
12-bit integers (−2048..2047); fractional coefficients are represented by a
common configurable final binary shift. No intermediate rounding/saturation.

For each output, `A = signed_bias32 + sum(unsigned_pixel * signed_coefficient12)`.
`ACC_WIDTH=max(32,BITS+12+ceil(log2(K*K)))+1` includes the exact sum and bias.
Maximum product magnitude is `(2^BITS−1)*2048`; sum magnitude is bounded by
`K*K*(2^BITS−1)*2048`. Bias adds at most 2^31. The implemented 33-bit signed
accumulator covers these ranges for all supported settings. No wrap is allowed.
Quantization: divide A by 2^cfg_shift, round to nearest with ties to even for
both signs, then clamp to [0,2^BITS−1]. Shift is 0..31; cfg_shift 32..63 is
rejected. Bias is expressed in the accumulator domain, before shifting.

`cfg_valid/cfg_ready` atomically transfers all K*K coefficients, signed bias,
and shift. Only complete frame boundaries accept configuration. Legal updates
pulse cfg_done; invalid shift pulses cfg_error and preserves previous settings.
An all-zero kernel is legal. Default is identity (center coefficient one, zero
bias/shift). Config has priority over a simultaneous new frame. Held config while
busy waits without stopping that frame. The next frame waits for final output
acceptance, preventing mixed coefficients or stale-tail output.

Low-active synchronous rst_n discards the in-flight frame, including the window,
MAC transaction and output slot. RAM storage is not cleared; valid state prevents
stale contents escaping. Marker errors are sticky diagnostics until reset.

The resource-bounded reference uses ONE signed multiplier and one accumulator.
A window is captured, then K*K taps run on consecutive cycles. Result appears
after K*K compute edges and can transfer on the following edge. MAC no-stall
latency and II are both K*K+1 (10 for K3, 26 for K5). Output backpressure blocks
the next MAC; the shared padded-window engine propagates stalls upstream.
Full-image throughput also includes row capture/replay and frame drain, so no
whole-frame II=1 claim is made. Width/height and border mode are static parameters.

Initial scope is RTL/model/simulation/isolated synthesis. P&R, physical RAM
mapping, host-vector board acceptance and production integration remain pending.

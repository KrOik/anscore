# Resource-bounded Stream 2D convolution

Complete isolated 3×3/5×5 true convolution for unsigned 8/10-bit pixels,
ZERO/REPLICATE borders, programmable signed 12-bit coefficients, signed 32-bit
bias, common scaling, round-to-nearest ties-to-even and output saturation.
The full arithmetic/interface contract is in [SPEC.md](SPEC.md).

Runtime configuration transfers the complete packed kernel, bias and shift in
one `cfg_valid/cfg_ready` transaction. Coefficient lane `i` occupies bits
`12*i +: 12`, row-major top-left to bottom-right. Convolution reflects the
window relative to these coefficients; it is not correlation. A center-only
coefficient one gives identity. For a normalized blur, supply integer tap values
and their common binary scaling shift. Bias is added before the shift.

Updates commit only with no frame in flight. Config priority prevents same-edge
input from using an old kernel. A next config may be held while busy; the current
frame finishes normally, then config is accepted before the next frame begins.
Invalid shifts 32..63 pulse cfg_error and retain previous settings. All-zero
kernels are valid. `cfg_done` acknowledges valid configuration; `busy` spans
first input through final output acceptance. SOF/EOL remain bound to each result.
Reset is low-active synchronous and discards all in-flight work without clearing
the row RAM. Sticky `marker_error` diagnoses framing; it does not resynchronize.

Architecture: shared padded window → captured K*K pixels → time-multiplexed
signed multiplier/33-bit accumulator → RNE and saturation → held output register.
One tap runs per compute clock. There is no intermediate truncation. Full legal
pixel/coefficient/bias ranges fit the accumulator; exact range derivation is in
SPEC. The final result is unsigned and clamped, so negative rounded values become
zero. Signed tie behavior is explicitly defined even for that clamped region.

**MAC II and latency are K*K+1: 10 clocks for K3, 26 for K5**, both checked in
simulation. With continuous valid/ready, adjacent outputs within a row meet that
II. Source capture/replay, row boundaries and frame drain can reduce average
rate further. No II=1 claim is made. The first-result latency from the first input
transfer is:

`WIDTH*(1+min(K/2,HEIGHT-1)) + (K-1)*(WIDTH+K-1) + K-1 + 4 + K*K + 1`.

All no-stall test frames assert this formula; every accepted MAC window has an
independent cycle check. Backpressure holds valid/data/markers and blocks the next
window until the previous result can leave. No dummy pixels are needed to drain.
WIDTH is bounded by the shared window's default 4096; dimensions and PAD_MODE are
static. There is no dynamic-size interface.

## Reproduce and simulation

```sh
python cores/signal_processing/dsp_isp_library/isp/convolution/test_convolution.py
python cores/signal_processing/dsp_isp_library/isp/convolution/synth_convolution.py
```

Final simulation: `evidence/sim_20260925_032529_241316/`. Twelve configurations,
612 complete frames, both borders, K=3/5, 8/10-bit, 1×1 and dimensions smaller
than the kernel. Kernel cases cover identity, blur, sharpening, asymmetric offset,
all-negative/all-positive extreme coefficients, zero kernel, ±32-bit bias bounds,
RNE half cases, shift31 and random signed taps. Image cases include zero, maximum,
impulse, ramp and seeded random values.

The independent exact-integer reference checks every output; a separate floating
accumulation/scaling path checks quantization error (maximum 0.5 output LSB in
the tested matrix). Signed RNE unit cases include ±0.5/1.5/2.5. Protocol tests
cover queued whole-frame configs, random source gaps, long/random output stalls,
marker stability, reset while output is held, multi-frame operation and malformed
markers. Every epoch rejects an illegal update and repeats a complete frame
without another legal config, numerically proving active settings were retained.
Forty-eight data/order/count/sideband mutation runs and five invalid static
parameter runs are rejected. Source/model/testbench snapshots, hashes, vectors,
expected outputs and real Icarus logs are retained in each fresh evidence directory.

## Isolated synthesis

Actual `synth_gowin -family gw2a -noalu` reports:
`evidence/synth_20260925_032534_347881/`. WIDTH=32, HEIGHT=24. Counts include the
complete configurable convolution core and window engine, excluding IO pads and
constants. MUX resources are listed separately from LUT1–4.

| K | Bits | Border | LUT1–4 | MUX2_LUT5 / LUT6 | FF | BSRAM | DSP |
|---|---:|---|---:|---:|---:|---:|---|
| 3 | 8 | ZERO | 1016 | 99 / 0 | 498 | 4 | 1 MULT9X9 |
| 3 | 8 | REPLICATE | 995 | 101 / 0 | 497 | 4 | 1 MULT9X9 |
| 5 | 10 | ZERO | 1615 | 180 / 1 | 1207 | 6 | 1 MULT18X18 |
| 5 | 10 | REPLICATE | 1617 | 169 / 1 | 1206 | 6 | 1 MULT18X18 |

The eight-bit configuration maps multiplication into one MULT9X9 plus surrounding
logic; the arithmetic interface still accepts all signed twelve-bit coefficients.
The script enforces at most four Gowin DSP-class cells. RAM maps to K SPX9 line
banks plus one DPX9B cache. No latch or width warning occurred; horizontal-history
register conversion and ABC's combinational-network note are expected.

These are mapped synthesis results, not P&R or 27 MHz timing acceptance. The wide
config interface must be connected to an internal config loader in a board wrapper,
not directly exposed as package pins. No board programming was performed. Physical
RAM/DSP behavior, externally injected board vectors, repeat programming and
production integration remain pending, including the repository's active inferred
RAM silicon investigation. Shared window RTL and other candidate modules were
not changed.

# INT4 depthwise 3x3 NHWC stream

Autonomous multichannel depthwise CNN cross-correlation accepts an interleaved
U8 NHWC raster. Each input channel has its own runtime signed INT4 3x3 kernel,
signed32 bias and integer quantization. Stride/dilation are one, padding VALID,
depth multiplier one. The output shape is (height-2)x(width-2)xchannels, ordered
y, x, channel. Spatial taps are not reversed.

```
acc[c] = bias[c] + sum_dy,dx (U8(image[y+dy,x+dx,c])-U8(x_zero))*S4(weight[c,3*dy+dx])
out[c] = sat_s8(RNE(acc[c]*U16(scale[c])/2^shift[c])+S8(zero[c]))
```

This provides multichannel raster processing with two interleaved line RAMs,
no full-frame memory and one shared narrow MAC. Output starts during raster
acquisition. It complements the existing single-input-channel frame convolution;
it does not implement grouped pointwise convolution, padding, activation,
batching or a whole inference network. Quantization follows the formula above;
TFLite/ONNX output-stage bit compatibility is not claimed.

One rising-edge clock, synchronous active-high public reset, no CE or CDC.
Hold reset over a rising edge. It cancels all ownership and clears kernel
validity. RAM payloads and horizontal histories are unreset. The reused RAM's
response controls also reset asynchronously through !rst. Both RAM and quantizer
run with their native clock active, so public transfers use ordinary valid&&ready.
All source fields must remain stable while valid is blocked. Held output,
configuration response and completion remain stable under backpressure.

Static bounds: MAX_CHANNELS1..16, MAX_WIDTH/MAX_HEIGHT3..1024, TAG_W1..32;
defaults4/64/64/16. Invalid static parameters elaborate a named missing module.
Runtime width/height/channels are full32-bit fields validated before narrowing;
width/height3..their maxima, channels1..MAX_CHANNELS. Commands latch U8 input
zero and an opaque tag. Configuration has priority over a simultaneous frame
offer. One owner remains until its response retires. A new command cannot
transfer on the prior completion's retirement edge.

| Configuration operation | Meaning |
| --- | --- |
| c_op0 | Write c_weights to channel c_channel, word c_word0/1. Word0 has taps0..7 in low-to-high nibbles. Word1 low nibble is tap8; padding ignored. |
| c_op1 | Write signed32 c_bias, U16 c_scale, unsigned shift0..31, signed8 c_zero. c_word is ignored. |
| c_op2 | Invalidate all channels. Index/data ignored. |
| c_op3 | Unsupported. |

Both weight words and metadata must be valid for every selected channel, even
when values are zero. Before any source transfer, a serial preflight checks all
selected validity bits. Missing configuration produces error2, zero inputs and
zero outputs. Configuration persists between frames and updates only at idle.
c_rsp_error0 success,1 full-width index/word range,2 opcode,3 child/internal.
Range/opcode errors preserve prior configuration; internal faults invalidate all
kernels. No externally supplied weights, ROMs or generators are required to
instantiate the core; callers supply model parameters at runtime.

Supply exactly width*height*channels scalars. s_sof marks only (0,0,0), s_eol
the last channel of the last x of each row, s_last the last scalar. Geometry
governs acquisition; wrong markers latch error3 and do not truncate a frame.
The source must finish a malformed raster or reset. Its numerical outputs are
provisional and should be discarded if definitive completion reports an error.
m_x/m_y name the cropped output's top-left coordinate; m_channel names its
channel. m_sof, m_eol, m_last follow the same output order and tag is unchanged.
m_clip flags final signed8 clipping, m_inexact discarded fractional bits before
offset/clamp. Negative ties round to even; scale zero and shift zero are legal.

rsp_error0 success,1 dimensions,2 missing kernel,3 markers,4 child/internal.
rsp_outputs counts actual external scalar output transfers, including
provisional outputs. Completion waits for final output retirement. Internal
faults can yield partial results; no rollback is provided. Every synchronous
RAM read AND write response is checked, and quantizer tags are checked.

`example/rgb_depthwise_filter.v` is an actual RGB24 pixel serializer and result
packer with runtime per-R/G/B kernels. It owns one input pixel and one output
pixel, adapts markers on channel0/2 and publishes signed-feature+128 display
bytes (xor sign bit). m_clip/m_inexact have one flag per R/G/B. Its rsp_pixels
counts complete external pixels; DONE is fenced behind owned outputs. An early
fault cancels partial input/pack state, while already published pixels drain.
It accepts no source pixels when the core fails preflight.

Resolve files.f and example/files.f from this directory. SOURCES.md records
deduplication, primary reference review and unchanged local dependencies.
ARCHITECTURE.md describes storage, widths and scheduling. Finite qualification
is planned in FINITE_PLAN.json and gated by SOURCE_REVIEW.json; status remains
RTL_CANDIDATE + INTEGRATION_CANDIDATE + HW_UNVERIFIED until actual evidence is
recorded. No synthesis/PnR/STA, board or PPA evidence is claimed.

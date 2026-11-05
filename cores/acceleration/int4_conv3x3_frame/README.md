# Configured INT4 convolution frame

`int4_conv3x3_frame` connects the unchanged synchronous3x3 row-window frontend
to the unchanged resident INT4 matrix engine. It consumes one raster of U8
single-channel pixels and emits a cropped signed8 feature map with runtime
output-channel count. It is a complete frame entry for a small quantized CNN
layer, with persistent kernels and automatic patch sequencing. No host patch
generation, frame RAM or per-pixel command submission is needed.

This implements the usual CNN **cross-correlation** convention: weights are
not spatially reversed. For output coordinate(x,y), channelr:

```
acc = bias[r] + sum_ky=0..2 sum_kx=0..2
       (U8(image[y+ky,x+kx]) - U8(cmd_x_zero)) * S4(weight[r,3*ky+kx])
y = sat_signed8(RNE(acc * U16(scale[r]) / 2^shift[r]) + signed8(zero[r]))
```

Stride and dilation are1, padding is VALID, source channels1. Output shape is
(height-2)x(width-2)xchannels, streamed y first, then x, then channel. There is
no activation function, pooling, tensor batching or multi-input-channel grouping.
Model export supplies integer bias/scale/shift/zero; no floating-point conversion
or ONNX/TFLite bit-exact output-stage compatibility is claimed.

## Configuration, clock and handshake

One rising-edge clock, **synchronous active-high rst**, no external CE and no
CDC. Hold reset across a rising edge; it cancels all commands, input, partial
outputs and completion, clears kernel validity and flushes both reused cores.
The window's existing asynchronous reset is asserted from rst and a registered
local frame-boundary reset flag; matrix reset is synchronous. Public ready/valid
signals are suppressed while rst is high. RAM payloads are not reset and stale
rows cannot form windows before two new rows have been accepted.

The window's native CE-qualified protocol is adapted by tying its CE permanently
high. All public handshakes are ordinary `valid && ready`; a caller using a
paused CE interface needs its own adapter. Sources hold all associated fields
while valid is blocked. Output and configuration/completion responses remain
stable under arbitrary stalls. Input/output/completion gaps have no timeout.

The static contract is MAX_CHANNELS1..64, MAX_WIDTH/MAX_HEIGHT3..1024, TAG_W1..32;
defaults8/64/64/16. Unsupported static values elaborate a named missing module.
Runtime cmd_width/height each lie in3..their static maximum; cmd_channels is
1..MAX_CHANNELS. The core captures dimensions, U8 input zero and opaque tag on
command acceptance. Only one frame is in flight, including held completion.

Kernel configuration is identical to `int4_weight_matvec`, with MAX_COLS fixed9:

| c_op | Effect |
| --- | --- |
| 0 | Write32-bit packed weights to c_row, c_word0 or1. Nibblei corresponds to tap8*c_word+i. Only low nibble of word1 is used; all other padding is ignored. |
| 1 | Write signed32 c_bias, unsigned16 c_scale, shift0..31 and signed8 c_zero for c_row. |
| 2 | Invalidate all kernel words and row metadata. |
| 3 | Unsupported operation. |

Each selected channel needs **both** words and its metadata, even when a word's
values are all zero. c_rsp returns error0 success,1 out-of-range index,
2 unsupported opcode; failed operations do not mutate the configuration. All
channels are independent and persist across frames until overwritten/reset/
invalidate. There are no generated ROMs or downloaded model weights.

Configuration and frame command share idle; configuration wins a simultaneous
offer. Its held response must retire before a frame can be accepted. No kernel
updates can occur during a frame. Before accepting any image pixel, a real matrix
command checks every selected kernel word/metadata row and enters vector-load
state. Missing configuration therefore returns completion error2 with zero
outputs and zero image transfers. A failed dimension check similarly returns
error1. An unaccepted source pixel remains the source's property.

## Framing and completion

Provide exactly width*height pixels in row-major order. s_sof is true only on
the first pixel, s_eol on the last pixel of each source row, s_last only on the
last pixel of the complete frame. All markers are qualified by input transfer.
Wrong markers do **not** shorten acquisition: configured dimensions govern
input consumption and numerical output. After all outputs transfer, completion
reports marker error3. Every output of such a frame is provisional and the
consumer discards it as a whole on that error. A source stopping at an early
LAST leaves the frame waiting; it must supply remaining pixels or reset.

m_x/m_y are zero-based coordinates in the cropped output, not source centers.
m_channel is0..channels-1. m_sof marks only output(0,0,0); m_eol marks the last
channel of the last x in each output row; m_last marks the final channel of
the final pixel. m_tag is the accepted frame tag. m_clip flags final saturation;
m_inexact flags fractional bits discarded by RNE, independently of clipping.
Negative ties round to even before output zero is added. Scale zero is legal.

The separate held rsp channel owns the definitive frame result. rsp_error is
0 success,1 dimensions,2 missing kernel,3 marker mismatch,4 unexpected child/
internal error. rsp_outputs counts actual successful output transfers, including
provisional data from a marker-error frame. rsp_tag remains stable. Completion
waits for both the window response and the final channel's external retirement;
it never races ahead of pending data. Error4 can describe partial output; no
rollback is implied. Frame-boundary window reset clears cancelled frontend state.

## Architecture and schedule

The frontend reuses two synchronous8-bit line memories, then one held72-bit
window is serialized in top-left-to-bottom-right order into the matrix's cached
vector. Matrix rows reuse that vector and stored packed weights. An output
patch owns its coordinates/markers until all its channels retire. The frontend
can hold its next window and one already-issued pixel while arithmetic stalls;
backpressure eventually reaches s_ready without losing or reordering pixels.

The scalar engine has one9x4 MAC and a40x17 row scaler, with the existing
three-slot64-to16 RNE pipeline and final signed8 offset/clamp. Accumulator40,
product57 and quantizer64 intermediates are exact for the nine-term formula;
there is one defined rounding point and final clamp. Dependencies are used once
through their existing canonical source paths; no mature source was modified.

After frame command edgeE, an always-ready, fully configured preflight admits
the first input no earlier than E+2*channels+4. Source pixels require at least
two clocks each for synchronous row-read/update. Once a captured patch enters
the matrix, nine input transfers are consecutive when its LOAD state is ready.
For a final tap atF, first channel valid appears after F+23 and can transfer at
F+24; further channels are21clocks apart when always ready. Matrix command
precheck runs again between patches. Frontend fill, channel work, row changes,
drain and completion all contribute; this is a serialized inference pipeline,
not a continuous one-output-pixel-per-clock engine. Arbitrary stalls remove any
unconditional completion deadline. No physical frequency/FPS claim is made.

Default line storage is1024bits, packed kernels512bits, row metadata488bits and
matrix validity24bits, plus the72-bit cached vector, held window and control/
arithmetic registers. At static maxima line storage is16384bits, packed kernels
4096bits, row metadata3904bits and validity192bits. No frame-sized storage,
external memory or vendor primitive is introduced. Qualitative resource risk is
**MEDIUM**: serialized throughput, dynamic selection/scaling and inferred memory
packing remain unmeasured. Output count fits32bits over the supported domain.

## Offline closure and finite qualification

Resolve `files.f` and `example/files.f` from this package root. The latter adds
`quantized_feature_map`, a named-port8-channel wrapper. [SOURCES.md](SOURCES.md)
records semantic comparison, primary external review, licenses and exact reused
hashes. New code is Apache-2.0. The full production closure is local.

`python run_checks.py` performs nine finite Icarus children: default/maximum/
example syntax and three compile/simulation pairs. Profiles are1channel/3x3/TAG1,
3channels/7x6/TAG8 and8channels/16x12/TAG16. A direct Python full-image3x3 oracle
uses arbitrary-integer sums and divmod-based RNE, independent of the window FSM
and matrix implementation. It checks a center-only kernel anchor, channel/
spatial order, arbitrary source gaps, downstream stalls, packed ninth tap,
unconfigured second word, dimension/index/opcode errors, marker-error completion,
signed bias/scaling extremes, half ties with odd zeros, frame reuse and four
live reset phases followed by reconfiguration. Exact inputs/dependencies/vectors
are archived before tools; each child has20seconds with bounded tree cleanup.
Missing/failed/timed-out checks stop later launches and cannot earn overall PASS.

Actual selected evidence is in B34_DELIVERY.json. Maturity is **LINT_PASS +
UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED**; LINT_PASS denotes Icarus
syntax/elaboration. No synthesis/PnR/STA, board run, PPA, inherited regression,
or whole-network inference validation was performed. Historical child hardware
results do not qualify this new configuration/composition.

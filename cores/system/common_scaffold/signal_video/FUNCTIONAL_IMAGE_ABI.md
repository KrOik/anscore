# Functional legacy image adapters

## Serialized window and external frame memory

`cip_image_window` mode0 preserves DATA_W1..32 pixel words through two synchronous
row buffers. Runtime source W,H>=3 fits MAX_WIDTH/HEIGHT (default64x64); logical
destination is(W-2)x(H-2). Each logical window produces nine complete DATA_W words
in row-major order, top-left first. SOF marks the first word of the first window;
EOL marks the ninth word of the last window in a logical row. Consequently a frame
contains9*(W-2)*(H-2) stream transfers. There is no padding. Param0/1 and all
bases/stride must be zero. Auxiliary/coefficient/memory ports are inactive.
Malformed source markers retain numeric windows and return final error2.

`cip_image_framebuffer` mode0 writes then replays one frame, mode1 writes only,
mode2 reads only. DATA_W1..32 pixels occupy the low bits of aligned32-bit external
words; writes zero higher bits and use strobe1111. Source/destination dimensions
match and fit MAX_WIDTH/HEIGHT (default64x64). Frame base and stride are BYTE
addresses, both aligned4; stride>=4*width. Last addressed byte must fit32bits.
Param0/1 and aux base must be zero. Only this entry actively uses the public
memory interface: exactly one outstanding request, separate write acknowledgement
or read-data response, shared CE. Connect physical-clock memory through a suitable
CE adapter. No auxiliary/coefficient traffic occurs.

Frame-memory requests and outputs hold under backpressure. Write-marker errors
finish writes and return error2; mode0 suppresses replay. Already committed writes
are not rolled back. Memory errors abort the command with error3, possibly after
partial writes/outputs. Read mode accesses caller-owned external memory without
requiring a prior write command. Reset cancels the local transaction; its external
peer must cancel outstanding responses at the same reset boundary. Both entries
latch config/tag, return error1 for unsupported modes/error2 for bad configuration,
and complete after the last output or write acknowledgement. New adapters have
functional simulation coverage, no synthesis/resource/timing/board acceptance.

## Programmable compact subpixel CNN

`cip_image_super_resolution` is actual model inference, not an alias to the
bilinear upsampler. It accepts low-byte scalar gray8 in DATA_W8..32 transport
and produces2x width/height. FEATURES=F1..16 (default4) controls three hidden
channel groups. The four layers are1->F5x5, F->F3x3, F->F3x3, F->4 3x3,
followed by PixelShuffle2 (channel=2*(out_y%2)+out_x%2). Every layer uses zero
padding. Hidden activations are integer unsigned16 after ReLU/saturation; final
samples saturate to gray8. The whole input and three hidden maps use synchronous
bounded internal memories. MAX_WIDTH/HEIGHT default64x64; destination is exactly
twice source, and supported parameter bounds keep dimensions within16bits.

Mode0 loads one model. All dimensions, params and bases/stride must be zero.
Supply exactly MODEL_WORDS=18*F*F+64*F+4 coefficient transfers at unique addresses
0..MODEL_WORDS-1, in any order. Each layer stores all weights first in
[output_channel,input_channel,kernel_y,kernel_x] order, then its output biases;
the next layer follows immediately. Weights are sign-extended signed16-bit Q8
in coeff_data32; biases are signed32-bit Q8 in pixel-value units. A full unique
valid load atomically switches model banks. Duplicate/out-of-range/noncanonical
weight words reject the staging bank and preserve the old model. Reset invalidates
the model; inference before a successful load returns error2.

Mode1 performs inference with a latched tag/shape and no params/bases/stride.
Each convolution accumulates bias+sum(input*weight) in signed48bits, then computes
floor((sum+128)/256) once; hidden layers clamp0..65535 and final outputs0..255.
Model coefficients are ignored outside mode0. Auxiliary/external memory ports
are inactive. Source high bits or malformed markers consume the frame and return
error2 without output. Unsupported modes return error1, bad load/config error2,
internal state failure3. Shared CE, input/output stalls, response holding and
load/capture/compute/held-output reset cancellation are tested.

Design reference: the four-convolution/ReLU/PixelShuffle structure in the
[official PyTorch super-resolution example](https://github.com/pytorch/examples/blob/main/super_resolution/model.py)
(accessed2026-10-18). This implementation uses compact equal-F hidden widths and
explicit fixed-point quantization, and does not claim compatibility with that
example's64/64/32-channel weights. No pretrained model is bundled. Synthetic
weight tests verify inference arithmetic; trained-model quality, PSNR/SSIM,
tiling beyond configured capacity, synthesis/timing/resources and board acceptance
remain unqualified. Image-quality improvement cannot be inferred from these tests.

## Dehaze pipeline and component entries

All four entries use runtime same-size bounded frames (default MAX32x32) and
shared CE. Frame/aux bases and stride are zero; coefficient/external memory ports
are inactive. Unsupported mode returns error1, invalid config/framing/high input
bits error2, internal failure error3. Command configuration and full tag latch.
Synchronous frame memories are overwritten before use after reset.

`cip_image_dehaze` supports low24-bit RGB in DATA_W24..32. Param0 low16 is omega
Q1.15 (0..32768), high16 is t0 Q1.15 (1..32768). Param1 low24 is manual RGB A,
bits26:24 dark radius, bits29:27 guided radius, bits31:30 zero. MAX_RADIUS defaults3,
supports0..7. Mode0/1 select manual/automatic atmosphere; mode2/3 additionally enable
guided refinement. AIRLIGHT_PERMILLE defaults1, GUIDED_EPSILON defaults100 in
gray-level-squared units. It performs actual per-channel atmosphere-normalized
dark-channel transmission, optional two-pass guided refinement, and RGB recovery.
Exact fixed-point formula and atmosphere tie selection follow the unchanged
production [dehaze ABI](../image/dehaze/README.md). These are not replaced with the
standalone scalar-dark approximation below. Input high transport bits retain
low24-bit processing but report final error2.

The component entries use mode0 only. `cip_image_dark_channel` accepts RGB24 in
DATA_W24..32, param0=spatial radius0..MAX_RADIUS, param1=0. It computes the minimum
of all RGB components over the replicated-border square neighborhood and outputs
zero-extended gray8. `cip_image_transmission` accepts low-byte scalar dark in
DATA_W16..32, param0={t0,omega} as above, param1=scalar atmosphere1..255. It outputs
zero-extended Q1.15 transmission from the existing scalar dark/A core.
`cip_image_recover` accepts RGB24 and atomically paired auxiliary Q1.15 transmission.
Param0 high16=t0, low16=0; param1 low24=RGB atmosphere. Auxiliary t>32768 is clamped
and reports error2. Recovery uses max(t,t0), signed division toward zero, and RGB8
saturation. Component framing/high-bit errors retain numeric output and report
final error2. Unused auxiliary ports are inactive on the other three entries.

Scalar transmission uses one numerator cycle and 24 restoring-division cycles
after input acceptance. Recovery shares a 23-bit restoring divider across RGB;
each channel takes one setup, 23 division and one result cycle. These are
enabled-cycle latencies; CE pauses all state and held output is stable under
backpressure. Signed division still truncates toward zero. Both bounded Tang25K
fixtures passed three SRAM/UART comparisons; hold timing remains unproven.

## Guided filtering and non-local means

`cip_image_guided_filter` mode0 uses low-byte scalar source and auxiliary guide,
atomically paired with matching markers. GRAY_BITS must8, DATA_W8..32. Param0 is
radius0..3, param1 epsilon Q8 (1..16776960), rounded upward to integer guide-square
units by ceil(param1/256). It computes signed covariance/variance coefficients,
then a second box average of coefficients and guide reconstruction. This is a
two-pass guided filter, not a box-filter substitute. Exact Q16 statistics and
source/output scaling are defined by the unchanged production filter wrappers.

`cip_image_nlm_denoise` mode0 accepts low GRAY_BITS1..12 scalar samples in
GRAY_BITS<=DATA_W<=32. Param0 low8=patch radius0..1, next8=search radius0..3,
high16=0. Param1 is positive h in unsigned GRAY_BITS.8 format. Each search sample
uses full patch SSD, index=min(255,floor(SSD*2^20/(patch_area*h^2))), weight from
round(65535*exp(-index/16)), followed by rounded weighted normalization. It does
not consume auxiliary input. NLM uses a private synchronous frame engine with exact
word-serial arithmetic; `(SSD <<20)` and rounded normalization preserve64-bit
unsigned wrap before division. Saturation shortcuts retain the same numerical
result. Latency depends on search/patch configuration and quotient saturation;
CE freezes computation and valid outputs hold under backpressure. The bounded
GRAY8/MAX8x6 public NLM case passed50MHz setup/resource gates and three actual
SRAM/UART runs (digest983E00FF); hold timing remains unproven. This does not
qualify default64x64 timing or realtime throughput. Guided filtering continues
to use its existing engine and has no new board claim from this NLM change.
Both entries replicate borders, produce same-size
frames bounded by MAX_WIDTH/HEIGHT (default64x64), latch config/tag, and keep
coeff/memory ports inactive. All bases/stride are zero. Source/guide high bits or
bad markers report final error2 while retaining numeric output; mode errors are1,
configuration errors2, internal failures3. CE/backpressure/reset are covered by
functional simulation; acceptance scope is limited as stated above.

## Affine and perspective inverse mapping

`cip_image_affine` and `cip_image_perspective` use mode0 nearest, mode1 bilinear,
mode2 atomic matrix loading. PIXEL_W1..16 packs unsigned channels exactly into
DATA_W<=32. Frame source is nonzero and fits MAX_WIDTH/HEIGHT (default64x64);
destination is any nonzero16-bit shape. Param0/1 and all bases/stride are zero.
Load commands require all dimensions zero, followed by exactly nine coefficient
transfers with unique addresses0..8: signed32-bit Q16.16 row-major inverse matrix.
Duplicates/out-of-range addresses reject the whole staging bank and preserve the
old matrix. Affine requires bottom row(0,0,65536). Reset restores identity.
Coefficients are accepted only during a load command; frame-time writes are ignored.

The matrix maps destination coordinates to source coordinates. Perspective divides
by the homogeneous denominator, truncating signed division toward zero, including
negative denominators. Results use Q16.8 coordinates; nearest/bilinear follow the
existing sampler's quantization and rounding. Negative/outside coordinates fill
black. A zero denominator fills black for that pixel and produces final error2.
Source-marker errors abort replay with error2. Unsupported mode returns error1;
configuration/load errors2, unexpected core failure3. Full tags are latched;
synchronous bounded frame memory, CE/backpressure/reset behavior are tested.
The shared mapper uses sixteen CSA product iterations plus six byte-fold
iterations and registered matrix sums. Input acceptance to mapper result is
25 enabled edges for affine and264 for perspective; scale remains240. All
state and transfers freeze when CE is low. The bounded MAX_WIDTH8/MAX_HEIGHT6
RGB24 acceptance fixtures passed three independent SRAM/UART runs each on
2026-10-19 with unchanged full-word goldens. Affine uses9752LUT4/3977FF/6BRAM/0DSP
and routes at51.71MHz; perspective uses9571LUT4/4001FF/6BRAM/0DSP at52.87MHz.
These results are bounded functional evidence with hold timing unproven.

## Integer-translation image stitching

`cip_image_stitch` is RGB24 with compile-time WIDTH/HEIGHT (default32x24),
MAX_SHIFT=S (default2). Commands must match source WIDTHxHEIGHT and destination
(WIDTH+2S)x(HEIGHT+2S), including both full-raster source and auxiliary frames.
Mode0 performs genuine luma SAD registration over integer shifts[-S,S]^2, then
RGB composition. MIN_CONFIDENCE controls rejection of ambiguous registration.
Mode1 uses supplied signed offsets: param1 low16=dx/high16=dy, mapping main(x,y)
to aux(x+dx,y+dy). Param0 is auxiliary overlap weight0..256 for both modes.
Mode0 param1 low24 is background RGB, high8 zero; mode1 background is black.
Only-overlap pixels blend; single-frame coverage preserves that frame.
The extended canvas is fixed, so large manual offsets clip. There is no automatic
feature/homography estimation or arbitrary-size panorama claim.

Configuration/tag latch; frame/aux bases and stride are zero, coeff/memory ports
inactive. Malformed paired frames, capture timeout and insufficient confidence
return error2; unsupported mode returns error1, internal state failure3. CE, separate stream
producers, backpressure, reset and recovery are covered. This new wrapper does not
inherit board qualification from the production fixed-shape kernel.

## `cip_image_threshold`

Each DATA_W-bit word is one unsigned grayscale sample, not packed RGB. The
interface is a stream command dispatcher; coefficients, auxiliary stream and
external-memory ports stay inactive. Frame base, stride and auxiliary base must
be zero. Configuration and tag are captured on command acceptance.

| cfg_mode | Algorithm | DATA_W | Dimensions | cfg_param0 |
|---|---|---|---|---|
| 0 | Fixed threshold, sample >= threshold | 1..32 | Source 1..65535 each; destination equals source | Unsigned threshold fitting DATA_W |
| 1 | Same-frame exact Otsu, sample > threshold | 8 | Source equals elaborated OTSU_WIDTH x OTSU_HEIGHT; destination equals source | Must be zero |
| 2 | Adaptive 3x3 exact mean, center > mean - offset | 1..16 | Source W>=3,H>=3,W<=ADAPTIVE_MAX_WIDTH; destination (W-2)x(H-2) | Sign-extended signed DATA_W+1-bit offset |
| 3 | Adaptive 3x3 exact Gaussian, center > weighted_mean - offset | 1..16 | Same cropped dimensions as mode2 | Same signed offset |

`cfg_param1` is 0 normal or 1 inverted (higher bits must be zero). Every binary
output is zero or all DATA_W ones. Gaussian weights are the outer product of
[1,2,1], normalized by16; adaptive comparisons use exact rational means without
rounding. Otsu uses the lowest threshold on tied scores, threshold0 for constant
frames. Fixed comparison includes equality; the other three modes use strict >.

Default DATA_W is24, so instantiate DATA_W=8 for all four modes. Otsu defaults
are OTSU_WIDTH=32, OTSU_HEIGHT=24, OTSU_COUNT_W=16; source dimensions must match
these compile-time parameters. Its synchronous frame RAM is bounded to at most
512x512, with1..24 count bits and pixel count <=2^OTSU_COUNT_W-1; invalid
elaboration parameters return an error from the child. Adaptive MAX_WIDTH
(default1920) must be3..65535. Arbitrary Otsu frame size at runtime is not
implemented. The dispatcher instantiates both adaptive branches where enabled;
resource sharing or device fit is not claimed.

All handshakes require `clk_en && valid && ready`; CE=0 holds state and pending
outputs/responses. Command startup can take multiple cycles before s_ready.
Fixed mode has one elastic output register and can overlap input/output for one
pixel per enabled cycle. Adaptive modes inherit the synchronous window maker's
cadence; Otsu captures, solves, then replays, with potentially long serial solve
latency. Do not infer video-rate throughput for all modes.

Exactly W*H input pixels are consumed for valid configurations. Fixed/adaptive
streams can have output before all input arrives; their malformed SOF/EOL frame
returns error2 after completing the stream, and the consumer must discard the
frame. Otsu validates input before replay and suppresses output on malformed
markers. Output markers describe the output dimensions. Completion occurs only
after the selected core has completed and the final output was accepted.

Responses retain the captured command tag: error0 success; error1 unsupported
mode (>3); error2 invalid configuration or malformed input markers (including
inapplicable data widths and Otsu histogram overflow); error3 internal core
failure. Rejected commands consume no pixels. A new command is blocked until
the completion response is consumed. Reset cancels commands, data and responses
across all branches; a different mode can then start without stale state.

```powershell
python cores/system/common_scaffold/signal_video/run_image_adapter_tests.py
```

The runner checks five DATA_W values, fixed-mode behavior, independent Fraction
Otsu/class-mean and2-D adaptive oracles, back-to-back mode changes, configuration
capture, malformed markers, invalid modes/configuration, CE/backpressure,
simultaneous input/output and capture/output reset cancellation. Temporary
executables/fixtures are automatically removed; small logs and hashes remain.
No synthesis, resource, timing or board validation is claimed for this adapter.
Use `rtl_functional_sources.f` for complete dependencies.

## `cip_image_brightness_contrast`

Mode0 operates on RGB888 (`DATA_W=24` only), with independently transformed
R/G/B8 lanes. `cfg_param0` is a signed32-bit brightness offset in[-512,511]
(must be sign extended). `cfg_param1[15:0]` is unsigned Q8.8 contrast,
`cfg_param1[23:16]` is an unsigned8-bit pivot, and bits31:24 must be zero.
For each channel x, the output is:

```
clip_0_255(floor(((x-pivot)*contrast +128)/256) +pivot +brightness)
```

This rounds half ties toward positive infinity, including negative products.
Identity configuration is brightness0, contrast256, pivot128 (`param1=0x00800100`).
The new arithmetic helper `cip_rgb_brightness_contrast.v` has three elastic
stages and captures configuration with each accepted sample. The legacy adapter
locks all parameters for a frame. This adds an arbitrary pivot rather than
changing the existing fixed-pivot ISP core or its tested arithmetic behavior.

## `cip_image_invert`

Mode0 accepts DATA_W1..32. `cfg_param0` is a DATA_W-bit XOR mask (higher bits
must be zero); `cfg_param1` must be zero. Output is `sample XOR mask`. An all-one
mask gives full intensity inversion, zero gives bypass, and e.g.0x00ff00 in
RGB888 inverts only the green channel. Sub-word bit ranges can also be selected.
The implementation reuses the registered `img_geo_pixel_invert` data path.

### Shared pointwise frame contract

Source dimensions must be1..65535 and destination dimensions must match.
Frame/auxiliary bases and stride must be zero; external memory, auxiliary and
coefficient ports are inactive. Configuration is captured on command acceptance.
Handshakes require common CE; startup takes multiple enabled cycles, then the
elastic pixel paths support one sample per enabled cycle without stalls.

Exactly width*height inputs are accepted. SOF/EOL are validated against input
position and regenerated before the kernel, so a malformed first SOF cannot
prevent configuration from taking effect. The adapter streams the frame and
returns error2 on bad markers after all outputs have been consumed; consumers
must discard that frame. Rejected commands produce no pixels: error1 is an
unsupported mode, error2 is invalid width/dimensions/configuration. Error0 means
successful completion. Responses preserve tags and remain held until consumed;
new commands are blocked while active or while a response is pending. Reset
cancels all pending data and commands.

```powershell
python cores/system/common_scaffold/signal_video/run_pointwise_tests.py
```

Checks cover supported inversion widths1/8/16/24/32, RGB888 arithmetic against
an independent rational oracle, unsupported RGB widths, parameter errors,
SOF/EOL errors, per-frame parameter capture, overlapped input/output, CE,
backpressure and reset recovery. No synthesis, resource, timing or board claim.

## `cip_image_color_convert`

DATA_W must be24. Mode0 converts packed RGB888 (R:G:B) to packed Y:Cb:Cr888;
mode1 converts Y:Cb:Cr to RGB. Both parameter words must be zero. The same
pointwise frame contract above applies: equal source/destination dimensions,
inactive memory/coefficient/auxiliary ports, captured command tag/direction,
regenerated SOF/EOL, delayed completion and explicit malformed-frame errors.
Direction is committed to the existing ISP core before its first accepted
SOF, including when the caller's input SOF is missing and later reported as an
error. A different direction can be commanded after consuming completion.

The implementation reuses `img_isp_colorspace`'s approximate BT.601 full-range
YCbCr4:4:4 coefficients and preserves its arithmetic:

```
forward: [Y,Cb,Cr] = clip(round(M * [R,G,B] /256) +[0,128,128])
M = [[77,150,29],[-43,-85,128],[128,-107,-21]]
inverse: [R,G,B] = clip(round(N * [Y,Cb-128,Cr-128] /256))
N = [[256,0,359],[256,-88,-183],[256,454,0]]
```

Here `round(x)=floor(x+1/2)` and clip is0..255 per channel. Because Y is an
integer, the inverse expression matches the existing core's separate Y plus
rounded chroma terms. Quantization/clipping means round-trip RGB is not
necessarily lossless. BT.709/BT.2020, studio/limited range, subsampling and
alternate channel layouts are not implemented by this ABI; modes>1 return
error1 and nonzero parameters or non24-bit data return error2.

The conversion kernel now uses four enabled pipeline stages: synchronous exact
constant-product ROM, pairwise sums, combined sums, and rounding/saturation.
An accepted kernel input reaches its output on the fourth enabled edge counting
the accepting edge; stalls extend this latency. The pipeline can accept one
pixel per enabled clock when the output advances. Shared CE and output
backpressure freeze the pipeline together. Integer coefficients, rounding,
saturation, and configuration commit at accepted SOF are unchanged.

`run_pointwise_tests.py` includes independent rational matrix-oracle tests for
both directions over all4096 points of a16-level3-D code-value cube, a full
neutral ramp, varying dimensions and seeded data. It also checks missing/extra
SOF, EOL errors, config capture, CE/backpressure, four capture/output reset
recoveries and explicit rejection of unsupported data widths. No synthesis,
resource, timing or board result is claimed for the new adapter.

## `cip_image_ccm`

DATA_W must be24 (RGB888). The command interface has two modes:

| Mode | Operation | Configuration |
|---|---|---|
| 0 | Process a frame with the most recently loaded table | Same-size pointwise dimensions; both parameter words zero |
| 1 | Atomically load a complete coefficient table | All source/destination dimensions and parameter words zero |

Frame/auxiliary bases and stride must be zero for both modes. External memory
and auxiliary stream ports are inactive. Unsupported modes return error1;
invalid command configuration returns error2 without accepting pixels or
coefficients. Reset initializes the matrix to identity and biases to zero.

Mode1 accepts exactly12 coefficient transfers through the existing
`coeff_valid/coeff_ready` interface. `coeff_addr`0..8 holds the row-major3x3
matrix of signed16-bit Q6.10 coefficients;9..11 holds signed16-bit integer R/G/B
biases. `coeff_data` must be the signed16-bit value sign-extended to32 bits,
e.g.-1 is0xffffffff. Every address must appear exactly once, in any order.
The host must hold address/data/valid until a common-CE handshake occurs.

The loader stages all12 transfers before writing the ISP shadow table. A
duplicate address, out-of-range address, or invalid sign extension is remembered;
the loader drains12 transfers, returns error2, and preserves the previous
table. A valid table is copied across12 accepted core-configuration cycles;
only then is a successful tagged response produced. Pixels are never accepted
during loading, and coefficient writes are never accepted during a frame.
There is no implicit timeout for an incomplete coefficient transaction.

The next mode0 frame commits the loaded shadow table on its first canonical
SOF. Loading several valid tables without an intervening frame selects the
last table. No writes to the table are accepted while a frame or completion is
pending, so every frame uses a single matrix. Per output channel i:

```
output[i] = clip_0_255(floor(sum(matrix[i,j]*input[j])/1024 +1/2) +bias[i])
```

The existing `img_isp_ccm` four-stage elastic data path and rounding are reused
unchanged. Same-size frame control, marker-error reporting, response holding,
CE/backpressure and reset cancellation follow the shared pointwise contract.
In particular, malformed input SOF does not suppress committing the selected
table; the streamed frame receives a final error2 and must be discarded.

```powershell
python cores/system/common_scaffold/signal_video/run_ccm_tests.py
```

Independent rational matrix tests include identity, channel permutation,
negative coefficients, bias/inversion, half rounding, extreme coefficients and
biases, seeded matrices, one-pixel and one-column frames, malformed markers,
CE/backpressure and frame persistence. Error tests verify rejected loads leave
the old matrix usable. Reset tests abort partial loading, shadow-table copying,
input capture and stalled output, then prove identity restoration. Widths8/32
are tested only for explicit rejection, not for numeric CCM behavior. Temporary
fixtures/binaries are cleaned automatically. No synthesis/resource/timing or
board claim is made for this adapter.

## `cip_image_gamma`

DATA_W must be24 (RGB888). This adapter uses the existing synchronous,
double-buffered `img_isp_gamma_lut` pixel core with a separate synchronous
two-bank768-byte staging store, without modifying the standalone core.

| Mode | Operation | Configuration |
|---|---|---|
| 0 | Process a same-size frame | param0=0 bypass,1 enable; param1=0 |
| 1 | Atomically load all three LUTs | All dimensions and parameter words zero |

Both modes require zero frame/auxiliary bases and stride. Memory/auxiliary
stream ports are inactive. Unsupported modes return error1; invalid command
configuration or DATA_W returns error2 without accepting coefficients/pixels.
Enabling without a successfully loaded table returns error2 before capture.
Reset returns the core to bypass and invalidates staged tables. RAM contents
are not reset and cannot be used until a new complete table has been loaded.

Mode1 accepts exactly768 coefficient transfers with strictly ascending
`coeff_addr=0..767`:0..255 R,256..511 G,512..767 B. `coeff_data[7:0]` is the
output value and bits31:8 must be zero. All transfers use common CE. The loader
drains768 words even on error; wrong/out-of-order/duplicate addresses or invalid
data return error2 and leave the previously committed staging bank usable.
There is no implicit timeout on an incomplete stream. Writes go to the other
staging bank, and the visible staging bank changes only after a fully valid
transaction. The next frame uses the last successful table, including when
multiple tables are loaded before any frame is processed.

For an enabled frame, startup serially copies the committed staging bank into
the pixel core's inactive LUT bank using synchronous reads (roughly1536 enabled
cycles plus setup/commit), then commits separately from the final write. The
first canonical SOF activates that table, including for that first pixel.
Every enabled frame repeats this copy because the standalone core requires a
complete newly loaded bank for every enabled commit. This supports repeated
frames and bypass/enable switches without silently using an incomplete bank.
After startup the pixel core supports one RGB pixel per enabled cycle when
unstalled. Output is direct per-channel table lookup; the host supplies the
curve, with no exponent evaluation performed in RTL.

The shared pointwise dimensions/markers/tag/error contract applies to mode0.
Command configuration and enable are captured; source traffic is blocked during
table loading/copying, coefficient traffic during frames is blocked, and frame
completion follows consumption of the last output. Malformed markers result in
a streamed frame with final error2. Reset aborts partial table loading, copying,
capture or held output; a subsequent bypass frame is independent of stale RAM.

```powershell
python cores/system/common_scaffold/signal_video/run_gamma_tests.py
```

Fixtures include identity/inversion tables, three distinct exponent-derived
host tables and seeded random LUTs, all256 addresses of every channel, repeated
frames, bypass/re-enable, multiple table loads without frames, rollback on four
invalid payload types, malformed markers, CE/backpressure and four abort/recovery
phases. Widths8/32 are checked only for explicit rejection. Temporary binaries
and fixtures are deleted automatically. The added staging capacity is1536 bytes
in RTL; actual BRAM/LUT mapping and timing have not been measured. No synthesis,
device-fit, timing or board claim is made.

## `cip_image_awb`

Mode0 accepts RGB888 only (`DATA_W=24`) and uses the existing gray-world
`img_isp_awb_auto` feedback chain:48-bit per-channel sums, hardware gain solver,
and the three-stage RGB gain pipeline. Dimensions, tags, inactive memory/aux/
coefficient ports and malformed-marker handling follow the shared pointwise
contract. Other modes return error1. Both16-bit gain bounds are packed into
`cfg_param0`: minimum in bits15:0 and maximum in bits31:16, as unsigned Q8.8;
minimum must not exceed maximum. `cfg_param1` must be zero. For example,
`param0=0x04000040` selects0.25..4.0. Invalid format/configuration returns error2
without pixels or statistics being accepted.

This is a streaming feedback algorithm: the first frame after reset uses unity
gains256; each subsequent frame uses the previous accepted frame's solved gains,
including that frame's first pixel. It does not recorrect the same frame. The
per-command bounds constrain the update computed from that command's frame,
which takes effect on the next frame. All-black statistics produce neutral
gains256, as specified by the existing solver, even when those gains lie outside
the configured bounds. Otherwise, for input channel sums S and T=floor(sum(S)/3),
the next gain is `clamp(floor(256*T/S[i]),minimum,maximum)`; a zero channel uses
the configured maximum. Pixel scaling is `min(255,floor((pixel*gain+128)/256))`.

The adapter waits for every output to be consumed, flushes final-frame statistics,
then waits for the automatic update to become pending before exposing completion.
This makes one-command-per-frame feedback deterministic rather than allowing the
host to start a new frame before its gain update is ready. Parameters remain
locked throughout this solver wait, which can take many enabled cycles. CE and
response backpressure hold both the pixel and completion paths. Reset cancels
capture, held output, statistics and in-flight solver results, restoring unity.

Input markers are regenerated before statistics collection. A malformed input
frame still contributes its exactly W*H accepted pixels to the next gain update,
but its streamed output returns error2 and must be discarded. Zero-channel
saturation is a defined solver diagnostic and does not turn the completion into
an error. Other sticky core errors return error3; reset clears those diagnostics.

`run_pointwise_tests.py` includes a sequential independent integer model of raw
frame sums, gray-world division/clamps and previous-frame gain application.
Cases cover color casts, neutral/all-black/zero-channel frames, changing gain
bounds, degenerate frame shapes, malformed markers, config capture, CE/stalls,
and reset during capture, held output and the post-frame gain solve. Non24-bit
widths are tested only for rejection. No additional frame RAM is introduced.
No new synthesis/resource/timing or board conclusion is claimed.

## `cip_image_bayer_demosaic`

DATA_W must be24. Each input word carries one unsigned RAW sample in its low
RAW_BITS bits, where the compile-time RAW_BITS parameter is8(default),10 or12.
Output words are RGB888 (R:G:B). Runtime modes select the original sensor phase:
0 RGGB,1 GRBG,2 GBRG,3 BGGR. Other modes return error1. RAW width is an instance
parameter rather than a runtime change; unsupported RAW_BITS or DATA_W returns
error2 before consuming pixels.

Source W/H must be at least3, with W<=MAX_WIDTH(default1920, valid3..65535).
Destination dimensions must be exactly(W-2)x(H-2). Both parameter words,
frame/auxiliary bases and stride must be zero. Coefficient, memory and auxiliary
ports are inactive. Accepted commands lock dimensions, sensor pattern and tag;
completion waits for the underlying frontend's last RGB consumption and held
response. All handshakes require common CE and preserve backpressure semantics.

The existing `img_bayer_window_frontend_draft` supplies two synchronous row
buffers, cropped3x3 windows and bilinear interpolation. There is no frame RAM
or border fill. At R/B sites the other chroma uses the four diagonals and G
uses the four orthogonal neighbors. At G sites R/B use the appropriate two
horizontal/vertical samples. Averages round half up in the original RAW width;
the final channel is shifted right by RAW_BITS-8 to produce8 bits. Pattern
parity refers to original source coordinates, including the cropped border.

The core consumes exactly W*H input samples regardless of malformed input
markers. Missing/extra SOF and wrong EOL are reported as error2 after the cropped
stream completes. Nonzero input bits above RAW_BITS are also remembered as
error2; processing uses the low RAW_BITS bits and the consumer must discard
the errored frame. Fatal child errors translate to error3. Command shape/config
errors return error2 without pixels; success returns error0 and the captured
tag. Reset cancels configuration/input/output and the next frame warms the row
buffers afresh, avoiding stale line-memory data in valid output.

```powershell
python cores/system/common_scaffold/signal_video/run_bayer_tests.py
```

Independent coordinate/color interpolation fixtures cover all four patterns,
all three RAW widths, minimum3x3 and single-output-row/column frames, black/white
and seeded input, cropping/markers, invalid commands, invalid high bits,
configuration capture, CE/stalls, and24 partial-input/held-output reset recoveries.
RAW9 and non24-bit DATA_W are checked only for explicit rejection. Temporary
fixtures/binaries are automatically cleaned. No new synthesis/resource/timing
or board result is claimed for the legacy adapter.

## `cip_image_mean_filter`, `cip_image_gaussian_filter`, `cip_image_median_filter`

Mode0 accepts one unsigned grayscale sample per word, DATA_W1..32. In particular,
the default24-bit word is a single24-bit gray value, not three8-bit RGB lanes.
Use separate instances or split/join color channels for per-channel RGB filtering.
The wrappers share `cip_image_window_filter_frame`: two synchronous line buffers
and one elaboration-selected existing `img_filter_kernel3x3` pipeline. No second
algorithm branch or frame RAM is instantiated by the shared helper.

| Entry | Fixed algorithm |
|---|---|
| mean | Nearest-integer mean of all nine samples, floor((sum+4)/9) |
| Gaussian | Weights outer([1,2,1],[1,2,1]), floor((weighted_sum+8)/16) |
| median | Fifth unsigned value of the sorted nine-sample window |

Source W/H must be at least3 and W<=MAX_WIDTH(default1920, valid3..65535).
Destination dimensions must be exactly(W-2)x(H-2); the outer ring is cropped
without padding. Both parameter words and frame/auxiliary bases/stride must be
zero; coefficient, external-memory and auxiliary-stream ports stay inactive.
Other modes return error1; unsupported configuration/dimensions return error2
before capture. Configuration/tag are captured when the command is accepted.

All input and output transfers require common CE. Startup configures the row
buffer; readiness/backpressure propagates through the window and kernel stages.
A single registered window slot holds all taps and SOF/EOL together between the
window maker and kernel. It cuts the combinational kernel-ready path into the
line-buffer controller and adds one enabled clock before the kernel accepts a
window when unstalled. A full slot blocks upstream acceptance until it drains;
backpressure can therefore extend latency. The kernel has elastic stages, but
the whole frame entry inherits the synchronous window maker's II>=2 cadence
and is not advertised as accepting a pixel every cycle. All public and child
asynchronous reset behavior remains intact; the slot clears on reset/abort.
Exactly W*H samples produce(W-2)*(H-2) results and regenerated output SOF/EOL.
Malformed input markers are remembered and return error2 after the streamed
output, which must then be discarded. Fatal child errors map to error3. Normal
completion waits for both the window response and the last external output
consumption. Reset cancels partial frames and the next frame warms line RAM
before exposing output; old RAM contents are not reset or treated as valid.

```powershell
python cores/system/common_scaffold/signal_video/run_window_filter_tests.py
```

The reference uses independent2-D Fraction means/Gaussians and sorted medians.
Three algorithms across DATA_W1/8/12/16/24/32 cover minimum and cropped shapes,
black/white/checker/impulse/ramp/seeded input, signedness/width extremes, missing/
extra SOF and bad EOL, config capture, invalid commands, CE/backpressure and
36 partial-input/held-output reset recoveries. Temporary binaries/fixtures are
automatically removed. Existing image kernels are unchanged. No synthesis,
resource/timing or board conclusion is claimed for these new frame adapters.

## `cip_image_sobel`, `cip_image_prewitt`, `cip_image_laplacian`

These cropped3x3 frame entries accept DATA_W1..32-bit unsigned gray samples,
including the default24-bit single gray value. Source W/H>=3, W<=MAX_WIDTH
(default1920, valid3..65535), and destination(W-2)x(H-2) follow the spatial-filter
contract. Both parameter words, all memory bases and stride must be zero;
coefficient, external-memory and auxiliary ports are inactive. Configuration,
mode and tag are captured on command acceptance. The shared synchronous row
buffer instantiates only the chosen existing edge kernel. The shared frame helper
uses the registered window slot described for the spatial filters above, adding
one enabled window-transfer clock before the kernel in the unstalled case.

Sobel uses horizontal/vertical derivative kernels with orthogonal weights[1,2,1];
Prewitt uses[1,1,1]. Gx is positive toward the right, Gy toward the bottom.
Magnitude is L1 (`abs(Gx)+abs(Gy)`), not Euclidean. Laplacian is
`response=4*center-north-south-east-west` with magnitude `abs(response)`.

Mode0 returns one display word per output pixel:
`min(2^DATA_W-1, magnitude >> MAG_SHIFT)`. MAG_SHIFT is an elaboration parameter,
default0, and must be nonnegative. Mode1 returns lossless full-precision values
before shifting or saturation. Let G=DATA_W+4 and W=ceil(G/DATA_W):

- Sobel/Prewitt output W words of signed Gx, then W of signed Gy, then W of
  unsigned L1 magnitude, per pixel.
- Laplacian outputs W words of its signed response, per pixel.
- Values are low word first. Signed top words are sign extended to DATA_W;
  magnitude's top word is zero extended. Reconstruct/interpret signed values
  as G-bit two's complement. For DATA_W8, W=2; for DATA_W1, W=5.
- SOF is asserted only on the first word of the first pixel. EOL is asserted
  only on the final word of the last pixel in that output row. Configured
  destination dimensions count pixels, not serialized words.

Modes>1 return error1; invalid command dimensions/parameters or elaboration
configuration return error2 before input. Source and kernel backpressure extend
through the one-pixel packet buffer. A pending serialized word and every frame
response hold under CE/stalls; packet formatting does not accept another pixel
until the current packet has been consumed. Completion waits for both the
underlying frame kernel and the final external serialized word, so a child
completion cannot overtake an unfinished packet. No one-pixel-per-cycle claim
is made for the complete window/serialization path.

Malformed input SOF/EOL is reported as final error2 after streamed output;
the consumer must discard it. Fatal child errors map to error3. Reset cancels
line-buffer state and partially emitted packets; the next frame warms RAM
before output. Standalone edge kernels and their signed arithmetic are unchanged.

```powershell
python cores/system/common_scaffold/signal_video/run_edge_tests.py
```

Independent2-D convolution and signed-word fixtures cover both modes, positive/
negative gradients, black/white/ramp/reversed-ramp/checker/impulse/seeded input,
DATA_W1/8/16/24/32, MAG_SHIFT0/2 and shift beyond magnitude width, config and
marker errors, shape capture, CE/backpressure, all word positions, and reset
during capture, held output or a partially transmitted signed packet. Temporary
fixtures and binaries are cleaned automatically. No synthesis/resource/timing
or board conclusion is claimed for these adapters.

## Morphology

`cip_image_morphology`: unsigned grayscale DATA_W1..32 (DATA_W24 is one gray
sample). Modes0/1/2/3/4: erosion/dilation/opening/closing/nonnegative gradient.
`cfg_param0[8:0]` is a nonempty 3x3 mask, row-major from top-left; higher bits
and param1 must be zero. Erosion uses x+b, dilation x-b (reflected mask).
Borders replicate at each pass. Gradient is max(0,dilation-erosion), including
asymmetric masks excluding the center. Source/destination dimensions must match,
be nonzero and fit MAX_WIDTH/MAX_HEIGHT (default64x64, capacity<=1048576).
Frame/aux bases and stride must be zero. Memory/aux/coefficient ports are inactive.
Each frame is fully captured in synchronous raw RAM; composite operations use
scratch RAM. Config/tag are latched, CE gates transfers, outputs tolerate stalls,
and response follows final pixel consumption. Error1 unsupported mode,2 invalid
configuration or malformed markers,3 internal failure. Reset aborts the frame.
The neighborhood address is registered before the synchronous RAM read. Each
of nine taps now uses READ (address), MEM_READ (RAM), REDUCE (extreme), adding
one enabled clock per tap (nine per pixel per pass) relative to the previous
helper. CE stalls freeze all stages; pixel values, markers and operation modes
are unchanged. Scratch uses one explicit synchronous read port shared between
neighborhood and gradient reads. The bounded 8x6 acceptance candidate passed
three actual SRAM/UART runs with unchanged numerical fixtures; its 50.14 MHz
setup report uses 1835 LUT4,375 FF,2 BSRAM,0 DSP including the isolated harness.
Hold timing remains unproven; this is not full configuration/timing acceptance.

## Histogram and global HE

`cip_image_histogram` and `cip_image_he` mode0 accept unsigned gray8 samples in
DATA_W8..32 words (default24); bits above7 must be zero. Nonzero high bits are
processed as low-byte samples but reported as final error2. This is grayscale,
not packed RGB. Source dimensions are runtime, nonzero and bounded by
MAX_WIDTH/MAX_HEIGHT (default64x64, product<=1048576). Param0/1, frame/aux bases
and stride must be zero. Memory/aux/coefficient ports remain inactive.

Histogram destination dimensions must be256x1, referring to bins rather than
serialized words. Bins ascend0..255; each is a complete unsigned32-bit count,
low word first, WORDS=ceil(32/DATA_W), with zero-padded final high word. SOF is
only on the first word of bin0; EOL only on the final word of bin255. Count
serialization never truncates to DATA_W or overtakes final output completion.

HE destination equals source dimensions. It emits one zero-extended gray8 pixel
per input pixel using floor(255*(CDF-CDFmin)/(N-CDFmin)). Constant frames retain
their occupied value. Same-frame input is captured in synchronous RAM, with
synchronous histogram RMW and LUT reads; the existing serial ratio core is reused.
Config/tag are captured on command acceptance. Shared CE gates transfers,
output/response hold under stalls, and response follows final external word.
Error1 unsupported mode;2 invalid config/high input bits/framing;3 child failure.
Reset cancels capture, calculation or partial output packets; memories are
cleared/rewritten on the next frame. New adapters have functional simulation
coverage, with no synthesis/resource/timing/board acceptance claim.

## Mirror/flip and rotation

`cip_image_mirror_flip` mode0 identity,1 horizontal mirror,2 vertical flip,
3 both (180-degree rotation); destination dimensions equal source.
`cip_image_rotate` mode0/1/2/3 rotates0/90/180/270 degrees clockwise.
Modes1/3 swap destination width/height, including nonsquare frames. Rotate
modes4/5 add centered arbitrary-angle nearest/bilinear sampling (specified below).
Rotate modes above5 and mirror modes above3 return error1.

Mirror and rotate modes0..3 preserve the complete unsigned DATA_W1..32 sample word, so DATA_W24 can
carry RGB888 with no color arithmetic or truncation. Runtime source dimensions
must be nonzero and fit MAX_WIDTH/MAX_HEIGHT (default64x64, capacity<=1048576).
Param0/1, frame/aux bases and stride must be zero; memory/aux/coefficient ports
are inactive. The shared `cip_image_permute_frame` captures the complete frame
in synchronous RAM and emits the reordered frame with recomputed SOF/EOL.
Config/tag are captured once, shared CE gates transfers, output/response hold
under stalls, and completion follows final output consumption. Error2 means
invalid dimensions/reserved config or malformed source markers; malformed frames
still output the word permutation and return the error at completion. Error3 is
reserved for internal failure. Reset cancels the frame; the next frame overwrites
the required RAM region. These entries have functional simulation coverage;
no new synthesis/resource/timing/board acceptance is claimed.

### Arbitrary-angle rotate modes4/5

Mode4 selects nearest and mode5 bilinear interpolation. Param0 is signed32
Q16.16 cosine c and param1 sine s of the clockwise angle. Each must be in
[-65536,65536], with c*c+s*s in [4294836224,4295098368]. The caller supplies
these coefficients; no floating-point trigonometry is implemented in RTL.
Destination dimensions may be any nonzero16-bit sizes; source bounds remain
MAX_WIDTH/MAX_HEIGHT. PIXEL_W1..16 partitions DATA_W1..32 into an exact number
of unsigned packed channels; these packing restrictions apply only to modes4/5.
Frame/aux bases and stride must remain zero; external memory/aux/coeff ports
are inactive.

Pixel centers use (dimension-1)/2. The inverse source coordinates are
x=c*dst_x+s*dst_y+tx, y=-s*dst_x+c*dst_y+ty, in Q16.16, where
`tx=floor(((src_width-1)*65536-c*(dst_width-1)-s*(dst_height-1))/2)` and
`ty=floor(((src_height-1)*65536+s*(dst_width-1)-c*(dst_height-1))/2)`.
Offsets outside signed32 are rejected with error2. The unchanged geometric
sampler truncates coordinates to signed Q16.8, uses half-up nearest/bilinear
rounding and clamps valid edge neighbors. Coordinates outside the source
rectangle produce black. Invalid coefficient/configuration or framing reports
error2; unexpected core failures report error3. Configuration/tag capture,
CE/backpressure, response holding and reset recovery are tested. Right-angle
mode transitions are also covered. Configuration uses six private serial CSA
products and registered byte sums for the exact norm and centered offsets.
Accepted valid configuration reaches the underlying frame-core handshake after
29 enabled edges, previously1 (+28); pixel mapper affine latency is25 enabled
edges, previously2. Dimension/coefficient-range failures still respond directly;
norm/offset validation follows captured arithmetic. Numeric goldens are unchanged.
The bounded MAX_WIDTH8/MAX_HEIGHT6 RGB24 acceptance fixture passed three SRAM/UART
runs on2026-10-19, using12191LUT4/5523FF/6BRAM/0DSP and routing at59.02MHz.
This is bounded functional evidence; hold timing remains unproven.

## Frame difference and motion mask

`cip_image_frame_difference` supports mode0 paired absolute difference,1 paired
binary mask,2 internal-history absolute difference,3 internal-history binary mask.
Inputs are unsigned scalar DATA_W1..32 grayscale samples; DATA_W24 does not mean
per-channel RGB processing here. Difference is abs(current-reference); masks are
all ones when difference > cfg_param0, otherwise zero (strict comparison).
Threshold must fit DATA_W. Param1, frame/aux bases and stride must be zero.
Source and destination dimensions match, are nonzero and fit MAX_WIDTH/MAX_HEIGHT
(default64x64, capacity<=1048576). Configuration/tag are captured on acceptance.

Paired modes consume current `s_*` and reference `aux_*` atomically, accepting
neither stream without its peer. Both streams need matching ordinal SOF/EOL;
output markers are regenerated from the configured shape. History modes ignore
aux input (aux_ready=0) and use a synchronous single-frame scalar RAM. Separate
read and write cycles avoid depending on RAM read-during-write semantics. Each
accepted current pixel replaces its old reference after reading; the frame is
committed as valid history only after final output is consumed without framing
errors. The first history frame after reset, shape changes, or a malformed history
frame outputs zero differences while establishing the new reference. Paired
commands and rejected commands preserve committed history. Switching back from
paired mode therefore compares against the last committed history-mode frame.

Shared CE gates all transfers. Output and response hold under stalls; completion
follows final output consumption. Error1 unsupported mode;2 invalid configuration
or malformed markers on active input streams;3 internal failure. Marker errors
still produce numerical outputs and invalidate an updated history frame. Reset
aborts the command and invalidates history without clearing RAM.

With continuously enabled CE and no stalls, paired modes assert output valid
one enabled edge after accepting a pixel; history modes assert it three enabled
edges after acceptance. History RAM data is captured before subtraction and
threshold selection is a separate registered state. Relative to the initial
implementation this adds one enabled clock per paired pixel and two per history
pixel. Output backpressure retains the pixel and blocks the next input.
The exact optimized source passed the five-width original reference regression;
the bounded Tang25K v5 board fixture passed three SRAM/UART runs. Its isolated
harness has registered ROMs and CE_DIV4. This is not a claim for all parameter
configurations or hold timing signoff.

## EWMA background modeling

`cip_image_background_model` operates on unsigned scalar DATA_W1..32 grayscale
samples, with an internal DATA_W+8-bit Qn.8 model RAM. This is a single EWMA
model, with no multi-Gaussian or per-channel RGB claim. Runtime source/destination
dimensions match, are nonzero and fit MAX_WIDTH/MAX_HEIGHT (default64x64,
capacity<=1048576). Param0 is a threshold fitting DATA_W. Param1[3:0] is update
shift0..8; bit8 freezes foreground updates, bit9 forces reinitialization for the
whole command. Other param1 bits, frame/aux bases and stride must be zero.
Auxiliary/coefficient/memory ports are inactive; aux_ready remains zero.

At each pixel, difference=abs(current-floor(old_model/256)); foreground requires
an initialized frame and difference>threshold. The new Qn.8 model is
old_model+floor((current*256-old_model)/2^shift), unless foreground freeze holds
the old model. Negative steps round toward minus infinity (signed arithmetic
shift), matching the existing low-level EWMA convention. Uninitialized models
start at current*256 with zero difference and no foreground indication.

Mode0 emits floor(new_model/256),1 pre-update difference,2 a foreground mask
(all ones/zero),3 the complete unsigned Qn.8 model serialized low word first.
Mode3 uses WORDS=ceil((DATA_W+8)/DATA_W); its high word is zero-padded. Destination
shape refers to pixel positions, not packet words. SOF is on the first word of
the first pixel; EOL on the last word of each row's final pixel. Model changes
persist across all four output modes. The full model output permits fractional
convergence and future host checkpoint comparisons without truncating to gray.

Config/tag are captured on command acceptance. History RAM read and write cycles
are separate and synchronous. Reset, size changes, forced reinitialization or a
previous malformed frame establish a new model from the next source frame.
A frame commits valid metadata only after its final external word is consumed.
Rejected commands preserve the model. Marker errors still emit numeric output
but return error2 and invalidate the model. Error1 unsupported mode,2 invalid
configuration/framing,3 internal failure. Shared CE gates transfers, outputs and
responses hold under stalls, and reset cancels partial model packets. These new
interfaces have functional simulation coverage; no synthesis/resource/timing or
board acceptance is claimed.

## Weighted image fusion

`cip_image_fusion` mode0 blends unsigned scalar DATA_W1..32 grayscale samples;
mode1 blends RGB888 channels independently and requires DATA_W24. For DATA_W24,
mode0 still means a single24-bit grayscale value; mode1 explicitly selects RGB.
This is co-registered two-frame blending; image registration and other fusion
algorithms remain separate features.

Param0 is auxiliary weight w in0..256; output is
floor((base*(256-w)+aux*w+128)/256), independently per channel in RGB mode.
Weights0/256 reproduce base/aux exactly;128 gives rounded averaging. Products
and sums retain full precision. RGB mode reuses `img_mf_rgb_blend_pipe` unchanged.
Param1, frame/aux bases and stride must be zero. Runtime source/destination
shapes match, are nonzero and fit MAX_WIDTH/MAX_HEIGHT (default64x64).
No frame RAM or external-memory traffic is required. Coefficient/memory ports
are inactive. Config/tag/weight/mode are captured once per command.

Base s_* and auxiliary aux_* streams transfer atomically; neither is accepted
without its peer. Both need configured ordinal SOF/EOL markers. Output markers
are generated from shape; malformed input still emits the numerical blend and
returns error2 after the final pixel is consumed. Error1 unsupported mode;2 invalid
shape/weight/reserved configuration or incompatible RGB width;3 internal failure.
Shared CE gates transfers and arithmetic. Outputs/responses hold under stalls;
reset cancels partial scalar arithmetic or RGB pipeline work. These new adapters
have functional simulation coverage, no synthesis/resource/timing/board claim.

## Full-raster RGB888 OSD

`cip_image_osd` requires DATA_W24 RGB888. Mode0 bypasses overlay,1 blends all
foreground pixels,2 blends only pixels unequal to the color key,3 replaces
non-key pixels opaquely. Param0 is alpha0..256 (mode3 uses256 regardless of the
valid supplied alpha). Param1[23:0] is the exact RGB color key; higher bits must
be zero. Alpha uses floor((base*(256-alpha)+overlay*alpha+128)/256) independently
per channel, through the unchanged existing `img_mf_rgb_blend_pipe`.

Both base and auxiliary streams are full rasters and transfer atomically, even
in bypass mode and at key-transparent positions. Placement is encoded by the
upstream foreground raster using key pixels outside the overlay; font/asset
rasterization and a sparse rectangle input interface are not implemented here.
Runtime source/destination dimensions match, are nonzero and fit MAX_WIDTH/
MAX_HEIGHT (default64x64). Frame/aux bases and stride must be zero; memory and
coefficient ports are inactive. No frame RAM or memory requests are required.
Config/tag/mode/alpha/key are latched at command acceptance. Output markers are
regenerated from shape; malformed SOF/EOL on either input retains numerical
outputs and returns error2 after the final pixel is consumed. Error1 unsupported
mode;2 invalid shape/alpha/key/width/reserved configuration;3 internal failure.
Shared CE gates transfers and the existing RGB pipeline. Outputs/responses hold
under stalls; reset cancels pending work. This entry has functional simulation
coverage, no new synthesis/resource/timing/board acceptance claim.

## Motion-adaptive temporal denoising

`cip_image_temporal_denoise` wraps the unchanged existing synchronous-history
`img_filter_temporal_denoise` with complete frame commands. DATA_W1..32 means
one unsigned grayscale sample (including24-bit scalar samples). Mode0 enables
recursive filtered-history use; mode1 rebuilds history from the current frame,
outputting current samples directly. Param0 is current-frame weight0..256;
param1 is a motion threshold fitting DATA_W. Frame/aux bases and stride must
be zero. Source/destination dimensions match, are nonzero and fit MAX_WIDTH/
MAX_HEIGHT (default64x64, bounded capacity<=1048576). Aux/coefficient/memory
ports are inactive; no auxiliary reference stream is consumed in this adapter.

When history is available and abs(current-previous)<=threshold, output is
floor((current*weight+previous*(256-weight)+128)/256). Otherwise output is current.
The stored reference is the previous successful filtered output, not raw input.
Difference equal to threshold still filters. First/reset/size-changed/previously
malformed frames bypass filtering while establishing new history. Rejected
commands preserve history. Mode1 explicitly refreshes it without resetting.

Config/tag/weight/threshold/mode are latched once; the adapter owns the full
TAG_W response tag independently of the child's fixed8-bit internal tag port.
Output markers follow configured shape. Malformed source markers retain numeric
outputs, report error2 at completion and invalidate history. Error1 unsupported
mode;2 invalid configuration/framing;3 unexpected child failure. Shared CE gates
transfers and arithmetic; outputs/responses hold under stalls; completion follows
final output consumption. Reset cancels pending work and invalidates history.
New adapter has functional simulation coverage with no synthesis/resource/timing
or board acceptance claim.

## Cropped bilateral filtering

`cip_image_bilateral_filter` mode0 accepts unsigned GRAY_BITS1..12 samples in
DATA_W>=GRAY_BITS and DATA_W<=32 words. Default DATA_W24/GRAY_BITS8 uses the low
byte as grayscale, not packed RGB. Higher input bits are detected: low gray bits
are processed but a final error2 is reported. Output is zero-extended to DATA_W.
Param0/1 are nonzero unsigned16-bit Q8.8 spatial/range sigma; higher bits must
be zero. Source dimensions must be at least3x3, width<=MAX_WIDTH (default1920);
destination is exactly(W-2)x(H-2), with no padded border pixels. Frame/aux bases
and stride must be zero; coefficient/aux/memory ports remain inactive.

The existing `img_filter_bilateral3x3` and its serial divider/weight LUT are reused
unchanged behind synchronous two-row window buffering. For each3x3 sample, index
is min(255,floor((dx^2+dy^2)*2^19/sigma_s^2)+
floor((sample-center)^2*2^19/sigma_r^2)). Weight is the existing Q0.16 LUT entry
round(65535*exp(-index/16)). The normalized result is
floor((sum(sample*weight)+floor(sum(weight)/2))/sum(weight)). The center always
has nonzero weight. This describes the implemented quantized kernel, rather
than an assertion of parity with every software bilateral variant.

Dimensions/sigmas/tag are captured. Kernel configuration is acknowledged before window setup; kernel input
backpressure prevents sampling until arithmetic setup completes. Completion
waits for both window retirement and final
external output consumption. Source marker errors retain numeric cropped outputs
and return error2. Error1 unsupported mode;2 invalid shape/sigma/gray profile/high
bits/framing;3 child failure. Shared CE gates transfers and calculations;
outputs/responses hold under stalls. Reset aborts and subsequent frames overwrite
row RAM before use. New adapter has functional simulation coverage, with no new
synthesis/resource/timing/board acceptance claim.

## Runtime nearest/bilinear/bicubic scaling

`cip_image_scaler` accepts arbitrary nonzero 16-bit destination dimensions.
Mode0 selects nearest (Q8 coordinate rounding, half upward); mode1 selects
bilinear; mode2 selects Catmull-Rom bicubic (a=-0.5). Modes3 and above
report error1. Source
dimensions must fit MAX_WIDTH/MAX_HEIGHT, default64x64. Param0/1, frame/aux
bases and stride must be zero. PIXEL_W1..16 defines unsigned packed channels;
DATA_W must be an exact multiple of PIXEL_W and at most32. Defaults24/8 mean
three independent8-bit channels. Channel order is preserved.

Inverse mapping is asymmetric-origin: qx=floor(x*src_width*256/dst_width),
similarly qy. Nearest rounds this quantized coordinate to the nearest source
sample; bilinear uses its8-bit fractions and four samples, with edge replication
and a single final half-up rounding after both dimensions. This is point
resampling; use the area downsampler for antialias reduction. Complete input is
captured in synchronous internal RAM before replay. Source framing error aborts
replay and returns error2. Invalid configuration/packing returns error2; unexpected
child errors return error3. Configuration and full TAG_W tag are latched. Completion
follows final consumed output, and shared CE freezes transfers and computation.
Auxiliary/coefficient/external memory ports are inactive. Reset cancels the frame;
RAM is overwritten by the next frame.

Bicubic uses the same Q8 asymmetric coordinates with a clamped4x4 source
neighborhood. For Q8 fraction t (integer0..255), the signed Q16 weights are
`w0=floor((-65536*t+512*t*t-t*t*t)/512)`,
`w1=65536+floor((-1280*t*t+3*t*t*t)/512)`,
`w2=floor((65536*t+1024*t*t-3*t*t*t)/512)`, and
`w3=65536-w0-w1-w2`. Exact unit coefficient sum preserves constants.
A signed64 accumulator sums all16 weighted samples per channel; the result is
`floor((sum+2^31)/2^32)`, then saturated to the channel range. There is no
intermediate horizontal rounding. Negative lobes may overshoot, so saturation
is intentional. This is not an antialias area reduction. The separate bicubic
frame RAM is synchronous; public mode selection gates both child handshakes.

The board-qualified bicubic implementation uses exact40/16-bit serial
coordinate division, a synchronous72x256 coefficient ROM, one shared serial
multiplier for horizontal/vertical products, and four16-bit carry stages per
64-bit tap accumulation. Each signed18-bit multiplier always retires18 bits
with four enabled carry stages per bit; negative weights use the exact
two's-complement sign-bit subtraction. There is no intermediate rounding.
Compared with the original combinational implementation, mode2 adds2504
enabled clocks per output pixel without downstream stalls. Modes0/1 are
unchanged. CE pauses and output backpressure further increase physical latency;
this implementation does not establish real-time video throughput.

Frozen `acceptance48/geo_optimized/scaler_v9` passed all21 original numerical
profiles (1423 commands,60615 output comparisons,45 reset cases), seven UART
normal/fault simulations, and three actual SRAM/UART loads on Tang25K.
Bounded board configuration is MAX8x6, packed8-bit channels, physical50MHz
with CE_DIV4, all three scaler modes and unchanged digest B4B7B42D. Resources
are8707 LUT/3438 FF/8 BRAM/0 DSP; setup50.21/52.76MHz. Hold remains UNPROVEN;
these results do not qualify all frame sizes, sustained video or full timing.
Production integration is byte-identical to that candidate's DUT dependencies.

The bicubic testbench watchdog is4000000 physical clocks per command and
2000000000ns globally; the old200000-clock limit failed after the intentional
serial arithmetic extension. The maximum fixture has221 outputs and48 inputs.
A conservative2600 enabled clocks/output and four physical clocks/step for
the fixed CE/ready/source schedules give221*2600*4+48*4+64=2298656 clocks.
The8199-output mixed profile needs at most852696000ns plus input/command
overhead at10ns simulation clocks, below the global bound. Numerical goldens,
configurations, reset, marker and error checks are unchanged. Host simulation
timeout is1200 seconds per profile; the original120-second timeout and other
failed candidates remain recorded. The full frozen regression took about
1547 seconds; integration binds hashes instead of repeating identical tests.

## Runtime antialiased downsampling and decimation

`cip_image_downsample` mode0 integrates exact pixel overlap areas and rounds the
weighted per-channel average once, half upward. Any nonzero destination shape
no larger than the source is accepted; param0/1 must be zero. Mode1 selects
unfiltered point decimation from source origin: param0/1 are horizontal/vertical
integer steps1..65535, and destination dimensions must be ceil(source/step).
Point decimation has no antialias filter. PIXEL_W1..16 and positive LANES define
packed unsigned channels, DATA_W=PIXEL_W*LANES<=32; defaults24/8/3. Source shape
must fit MAX_WIDTH/MAX_HEIGHT (default64x64). Frame/aux bases and stride must
be zero; auxiliary/coefficient/external memory ports are inactive.

Mode0 stores a bounded frame in synchronous RAM and rejects malformed framing
with no output. Mode1 streams selected samples, so a framing error can follow
already emitted pixels. Both return final error2 on malformed source markers;
unsupported mode returns error1, invalid configuration error2, unexpected child
failure error3. Shape/mode/steps/tag are latched; output and response hold through
backpressure/CE pauses. Completion follows final output consumption and capture
retirement; reset cancels either path.

Both paths preserve exact integer arithmetic using enabled-cycle state machines.
Mode1 validates the two ceil(source/step) results with16-bit restoring division
before starting capture. Mode0 shares one bounded restoring divider across four
footprint-boundary coordinates and each output channel's final half-up average.
Each division uses W bit iterations plus start/retirement cycles, where
W=max(PIXEL_W+XW+YW,2*XW,2*YW), XW=clog2(MAX_WIDTH+1),
YW=clog2(MAX_HEIGHT+1), with dimension widths at least1. Source taps advance
through separate read, edge, overlap, weight, product and accumulation stages.
These additional enabled cycles increase latency; CE pauses stop progress and
backpressure holds the final output. Numerical values and supported modes are
unchanged. The exact v4 bounded Tang25K fixture passed three SRAM/UART runs;
this does not establish all-parameter timing fit or hold timing signoff.

## Integer bilinear upsampling

`cip_image_upsample` mode0 uses param0 as integer scale1..15; param1 must be zero.
Destination dimensions must equal source dimensions times scale and fit16bits.
DATA_W8/16/24/32 carries independent unsigned8-bit channels. Source dimensions
are nonzero and bounded by MAX_WIDTH/MAX_HEIGHT (default64x64). Frame/aux bases
and stride must be zero. This is bilinear interpolation, not learned super-resolution.
It uses the same asymmetric Q8 coordinate mapping, replicated boundary samples,
and final single half-up rounding as scaler mode1 above. Configuration/tag are
latched. Synchronous internal frame RAM is overwritten before replay; malformed
source markers return error2 without output. Unsupported mode returns error1,
invalid packing/shape/scale/reserved fields error2, unexpected core failure error3.
Auxiliary/coefficient/external memory ports are inactive. Shared CE and downstream
backpressure hold data/responses; reset cancels capture, compute or held output.
No new synthesis or board acceptance is claimed.

## Runtime tiled CLAHE

`cip_image_clahe` mode0 operates on low-byte gray8 in DATA_W8..32 transport;
default24 is scalar grayscale, not RGB. Other GRAY_BITS profiles reject.
Source/destination dimensions match and fit MAX_WIDTH/MAX_HEIGHT (default64x64).
Param0 is an absolute per-bin clip count1..16777215. Param1 low16/high16 specify
nominal tile width/height. Each dimension is positive and at most the frame
dimension; odd and1-sized tiles are supported. The ceil-grid contains at most256
tiles. Right/bottom edge tiles use the remaining actual dimensions. Clip*256
must accommodate the nominal tile area (and therefore every edge tile). Frame/aux bases
and stride must be zero. Auxiliary/coefficient/external memory ports are inactive.

Each tile is clipped and excess is redistributed by repeated ascending-bin unit
sweeps, never exceeding clip. LUTs are floor(255*cumulative_count/tile_pixels),
without CDF-min subtraction; tile_pixels is the actual tile area. LUT
interpolation uses actual geometric tile centers
`center2(i)=2*i*nominal_size+min(nominal_size,frame_size-i*nominal_size)-1`,
with Q8 fractions measured between neighboring doubled centers. A single tile
uses zero fraction; outer borders extend the nearest tile. There is a single
half-up rounding of the full bilinear sum. This strict variant makes no OpenCV
bit-parity claim. A bounded synchronous frame RAM, histogram and tile LUT RAM
hold state. Runtime frame/tile/clip/tag configuration is captured on acceptance.

Unsupported mode returns error1; invalid shape/tile/clip/transport returns error2.
Malformed SOF/EOL consumes the complete frame and returns error2 without output.
Nonzero high transport bits are ignored numerically and produce final error2
after ordinary low-byte processing. Unexpected internal failures return error3.
Shared CE and backpressure hold payloads/responses; reset aborts active work.
This new runtime adapter is distinct from historical fixed-size CLAHE board
candidates; no new synthesis, timing, resource or board acceptance is claimed.

## Complete bounded-frame Canny

`cip_image_canny` mode0 wraps the unchanged existing `img_edge_canny` with frame
commands. GRAY_BITS1..12 samples occupy the low bits of DATA_W>=GRAY_BITS and
DATA_W<=32 transport words. Default DATA_W24/GRAY_BITS8 is one low-byte grayscale
sample, not RGB. Nonzero high input bits are processed as low gray samples and
reported as final error2. Output masks are0 or(2^GRAY_BITS-1), zero-extended to
DATA_W. Runtime source/destination shapes match, are nonzero and fit MAX_WIDTH/
MAX_HEIGHT (default64x64, capacity<=1048576). Param0/1 are low/high unsigned
GRAY_BITS+4-bit L1 gradient thresholds with low<=high; higher bits must be zero.
Frame/aux bases and stride must be zero. Auxiliary/coefficient/memory ports
are inactive; all frame state stays in the existing core's synchronous memories.

Stages are fixed rounded3x3 Gaussian (separable weights1,2,1, sum16), Sobel L1
magnitude, four-direction NMS, double threshold and complete8-connected weak-edge
propagation to a fixed point. Borders replicate for local filtering and NMS.
Direction thresholds use106/256; NMS keeps equal neighboring magnitudes, suppresses
zero magnitude and strict smaller values. Magnitudes>=high start strong edges;
remaining retained values>=low are weak. Only weak pixels connected to strong
pixels survive. The existing repeated raster propagation implements full
connectivity rather than a single-neighbor approximation; the independent test
reference uses a graph queue. This variant does not assert universal OpenCV parity.

Shape/thresholds/tag are latched at command acceptance. The adapter owns TAG_W
metadata independently of the child's8-bit internal tag. Malformed source
markers retain numerical output and report error2 after final output consumption.
Error1 unsupported mode;2 invalid configuration/framing/high input bits;3 unexpected
child failure or propagation-limit failure. Shared CE gates transfers/processing,
outputs and responses hold under stalls, and reset cancels capture, processing
or held output. Subsequent frames overwrite required memory regions before use.
New adapter has functional simulation coverage, no synthesis/resource/timing or
board acceptance claim.

## 2026-10-18 acceptance pipeline updates

Public median frame processing selects the optional five-stage median kernel
(2+2+2+2+1 sorting layers), instead of three stages. Initiation interval stays
one; enabled unstalled kernel latency is five edges including acceptance.
The standalone generic kernel defaults to the original three stages. CE,
backpressure and SOF/EOL alignment remain unchanged and were regression tested.
Window frame counters use exact byte carry increments and a registered final
count comparison without adding cycles.

Adaptive mean/Gaussian threshold kernels now use five actual arithmetic stages,
with II=1 and all stages frozen by CE/backpressure. Otsu uses exact serial
multiplication with B_W+ceil((A_W+B_W)/8) enabled cycles; LOAD and SCAN each add
one enabled cycle, and delta subtraction uses ceil(DW/8) enabled cycles.
External count widths and numerical thresholds are unchanged. Threshold and
median frozen acceptance cases each passed three actual board UART comparisons;
hold qualification remains unproven. Consult acceptance48/ACCEPTANCE_STATUS.md
for source bindings and bounded configurations rather than inferring universal
video throughput or full timing signoff from these tests.

Background-model EWMA arithmetic now has separate delta and shifted-delta
registers before model update, adding two enabled processing cycles per input
pixel; all modes, exact signed shift arithmetic, persistent history, marker
errors and CE/output hold behavior are retained. Original five-width reference
regression and three actual board comparisons passed at62.47MHz setup with
1018LUT/414FF/6BRAM/0DSP including harness. AWB statistics uses parallel byte
carry counters; saturation/wrap, statistical frame boundaries and latency are
unchanged. Its original8reference fixtures and production20pointwise profiles
passed, followed by three actual board comparisons. Hold is still unproven.

CLAHE now registers configuration, separates coordinate/offset stages and uses
an exact eight-step Q8 fraction calculation. Compared with the previous pixel
coordinate stage this adds10enabled cycles per pixel; ratio iteration count
also depends on the exact MAX-frame-derived count width. Standalone helper
COUNT_WIDTH defaults to24. The public wrapper derives sufficient count width
and clamps clip to maximum possible tile count, which preserves the function
for larger clip values. All original1047commands/59357outputs/9resets and15218
additional clip-bound comparisons passed before three actual board passes.

Framebuffer configuration uses a private exact CSA multiplier (16iterations
plus6byte-fold cycles) and an8cycle exact64bit final-address fold. Next-row
addresses are precomputed during memory requests; source/destination address
validation, overflow and bus-error semantics are preserved. Original five
supported widths plus width33 rejection passed again in production, followed
by three board passes at72.84MHz setup. These cycles increase command setup
latency; no continuous frame-rate target is claimed.

Fusion uses a separate four-stage RGB blend helper, retaining the original
three-stage helper for OSD. Scalar fusion uses9CSA multiplication iterations
plusceil((DATA_W+9)/8) byte-fold cycles and explicit result handshakes. Exact
rounding/limits and immediate command-following input behavior are retained;
II1 applies to the RGB helper only. Original5public reference profiles and
4096stream helper records passed, along with three actual board comparisons.
All evidence remains bounded functional testing with hold timing unqualified.

Bilateral acceptance implementation uses the same256 exact exponential weights
in synchronous initialized ROM, with an unreset RAM output register used only
after its read stage. Valid/control reset still cancels outstanding work. Each
tap captures weight, uses a private exact16-step CSA multiplier followed by
ceil((PIXEL_W+16)/8)byte-fold steps, and folds numerator/denominator addition
in ceil((PIXEL_W+20)/8) byte steps. Final rounding uses the same byte-fold count.
The extra stages change latency; exact Q8.8 sigma configuration, Q0.16 weights,
rounding, clipping, crop shape and stream markers are preserved. Divider byte
borrows preserve two enabled stages per quotient bit. Original7public parameter
profiles and three actual board comparisons PASS at63.94MHz; production repeat
also PASS (bilateral_adapter_20261018T162649Z_b3e4ae80). Resource2162LUT/1541FF/
5BRAM/0DSP includes board harness, not a standalone-kernel area assertion.


### Super-resolution production pipeline, 2026-10-19

The exact board-tested v7 public RTL uses bounded addresses, one synchronous
coefficient RAM read port, four small partial products, and three 16-bit
accumulator carry stages. Arithmetic and atomic two-bank model replacement
remain unchanged. Each MAC term takes eight enabled cycles, six more than
the original implementation. This is programmable inference; no pretrained
model, image-quality or sustained-video performance acceptance is implied.

The original five profiles passed 258 commands, 6720 numerical comparisons
and 16 reset cases. F16 reset-to-first-output needs
20176 terms * 8 + 579 = 161987 enabled cycles; its reset-only wait is now
170000. The original main 3000000-cycle and global 4000000000-ns watchdogs
remain unchanged. The host VVP timeout is 600 seconds (original regression
completed in about 239 seconds); no oracle, mode or coverage is removed.

Frozen evidence: `board/tang25k/acceptance48/scalar_dehaze_optimized/`
`super_resolution_rtl_v7/original_public_regression_20261019_010950/summary.json`
and `functional_board_frozen_seed3_20261019_011832_039999.json` in that case
directory: three actual volatile-SRAM loads and exact UART PASS, digest
`0A8FF166`. Board scope is DATA_W=8, FEATURES=1, MAX=8x6, CE_DIV=4.
Resources: 4893 LUT, 3298 FF, 6 BRAM, 0 DSP; setup 61.68/61.30 MHz
for the 50-MHz target. Hold timing remains UNPROVEN. See the case-local
`PRODUCTION_BINDING.json` for exact source/evidence hashes.

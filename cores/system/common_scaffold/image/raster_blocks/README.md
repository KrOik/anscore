# Synchronous-frame raster / 8x8 block reorder

`img_raster_blocks` is a grayscale sample reorder buffer for frame-level block
processing such as JPEG. Repository source search found a raster-coordinate
helper, but no equivalent raster/block frame reorder. It performs no DCT,
quantization, color conversion, JPEG syntax or compressed-byte coding.

Parameters: `BITS=8,10,12`, `WIDTH,HEIGHT=1..4096`, `TO_BLOCK=1` for raster-to-block
or `0` for block-to-raster. Invalid parameters are rejected at elaboration. Both
directions use the same source module; instantiate two modules for a roundtrip.

## Coordinate order and padding

Raster order is top-to-bottom rows, left-to-right pixels. Block order is blocks
left-to-right then top-to-bottom; inside each 8x8 block, samples are row-major.
There are `ceil(WIDTH/8)*ceil(HEIGHT/8)` blocks, each with exactly 64 samples.

Forward reads sample `(min(block_x*8+inner_x,WIDTH-1),
min(block_y*8+inner_y,HEIGHT-1))`, so right/bottom edges are replicated, including
the bottom-right corner. A 1x1 frame produces one 64-sample block with the same
sample repeated. Inverse consumes every padded block sample but writes only
coordinates inside the real frame. Padding values are ignored, even if unrelated
to neighboring pixels; it then emits exactly WIDTH*HEIGHT raster samples.

## Interface and markers

Inputs: `s_data[BITS-1:0]`, `s_valid/s_ready`, `s_sof`, `s_eol`,
`s_block_first`, `s_block_last`. Outputs have the corresponding `m_` names, plus
`m_frame_last`. Valid and marker signals accompany each sample.

| Direction | Input markers | Output markers |
| --- | --- | --- |
| TO_BLOCK=1 | SOF only on frame sample 0; EOL on the true final pixel of each row; both block markers must be 0 | SOF only on the first sample of the first block; EOL on inner_x=7 in **every block row**; block_first on index0; block_last on index63; frame_last on the last sample of the last block |
| TO_BLOCK=0 | SOF/EOL/block markers must match the forward output convention above | SOF on raster sample0; EOL on each true row end; both block markers are 0; frame_last on the final real pixel |

Block-stream EOL therefore does not mean the original image row end. Every block
has eight EOL-marked samples. There is no input frame_last port: compile-time
geometry determines frame length. Metadata is regenerated from checked coordinates.

All transfers require `clk_en && valid && ready` at a rising clock edge. Ready is
low with CE disabled, reset asserted or while the module emits its buffered frame.
Output valid remains asserted with stable data/markers under backpressure or a
CE pause. Sources must hold pending input payload/markers until accepted; consumers
must obey the same CE-qualified transfer convention.

## Buffering, latency and resources

This is a **single full-frame buffer**, not a strip buffer or ping-pong DMA.
Storage is WIDTH*HEIGHT*BITS logical bits, with no storage for padded samples.
Memory is written only during capture; output reads are synchronous in a separate
clocked RAM process. Neither RAM contents nor its read register is reset, allowing
Gowin block-RAM inference. A frame is never emitted until its full input sequence
has been accepted and validated. Next-frame input waits until current output ends.

Capture accepts up to one sample per enabled edge. Emission uses an ADDRESS edge
for the synchronous RAM read followed by an EMIT transfer edge: at most one sample
per two enabled edges. First output valid appears one enabled edge after the final
capture transfer; the earliest first output transfer is the next enabled edge.
Without stalls, forward capture+emission takes approximately WIDTH*HEIGHT +
2*64*ceil(WIDTH/8)*ceil(HEIGHT/8) enabled edges, and inverse uses the reverse counts.
Dimension limits describe functional addressing, not on-chip BRAM capacity:
large frames require a device with enough memory or an external-memory redesign.
Address constant-stride multiplication is explicit shift/add and uses no DSP.

## Malformed input and reset

`protocol_error` is sticky until reset; `error_pulse` is a one-enabled-cycle event
and holds while CE is disabled. Any marker mismatch on an actively captured frame,
or on a candidate SOF, drops the entire in-progress frame and the offending sample.
The module then consumes and discards samples until the next SOF with valid first-
sample marker values. An unexpected SOF that caused an error is **not** reused as
the start of a replacement frame: the caller must submit a new complete frame.
At power-up/reset the same resynchronization state waits for a legal SOF, silently
discarding preceding non-SOF samples. Already completed/emitting frames block input,
so malformed later data cannot alter their RAM.

Asynchronous low `rst_n` aborts partial capture or pending output, clears positions
and error status, and returns to SOF resynchronization. Old RAM data is inaccessible
as a valid frame: every real sample must be overwritten by a newly captured full
frame before any output becomes valid. No timeout is provided for missing pixels.

## Reproduce and evidence

From repository root:

```powershell
python -B cores/system/common_scaffold/image/raster_blocks/run_tests.py
```

Twelve profiles cover 8/10/12 bits and 1x1,8x8,9x13,17x3 geometry. Python creates
independent image-coordinate oracles for padded block order and original raster
order. SV tests actual forward->inverse wiring for two images and independently
feeds a third inverse image with random unrelated padding. This verifies both edge
replication and padding discard without relying solely on complementary transforms.
Random source/link/sink pauses, CE stalls, all output markers, stable blocked
payloads, malformed forward/inverse markers, recovery and capture/output reset abort
are covered. `test_result.json` records the final RTL hash. Temporary vectors and
simulator binaries are removed automatically.

Isolated synthesis (put OSS CAD Suite bin/lib on PATH):

```powershell
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/raster_blocks/img_raster_blocks.v; chparam -set WIDTH 17 -set HEIGHT 13 -set BITS 8 -set TO_BLOCK 1 img_raster_blocks; synth_gowin -top img_raster_blocks -noalu -nolutram; stat"
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/raster_blocks/img_raster_blocks.v; chparam -set WIDTH 17 -set HEIGHT 13 -set BITS 8 -set TO_BLOCK 0 img_raster_blocks; synth_gowin -top img_raster_blocks -noalu -nolutram; stat"
```

17x13,8-bit final mapping: forward 99 LUT1..4 + 6 MUX2_LUT5, inverse 96 LUT1..4 +
9 MUX2_LUT5; each uses 24 FF, 1 DPX9B and 0 DSP. Both CHECK passes report 0 problems.
The retained `initial_address_dsp_*` logs document the superseded ordinary constant
multiply mapping; use `synthesis_forward.log`/`synthesis_inverse.log` for final
shift/add RTL. No JTAG, JPEG bitstream decoding, placement/routing or setup/hold
signoff is claimed. Shared source/runner integration belongs to the parent task.

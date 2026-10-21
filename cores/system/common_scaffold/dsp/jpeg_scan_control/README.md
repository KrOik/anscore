# Multi-block JPEG entropy scan and restart control

`jpeg_entropy_scan_controller.v` wraps the existing unchanged
`../jpeg_bitstream/jpeg_entropy_bitpacker.sv`. Input tokens already contain
Huffman code bits and amplitude bits. This module concatenates entropy across
ordinary block boundaries, flushes only at configured restart boundaries or
scan completion, emits raw numbered restart markers, and coordinates DC
predictor reset events. It does not build Huffman tables, perform DCT or
quantization, or emit JPEG headers/EOI/SOI.

## ABI and scan boundaries

A `start_valid && start_ready && ce` handshake atomically latches
`cfg_total_blocks[31:0]` (must be >0) and `cfg_restart_interval[31:0]`.
Interval 0 disables restarts. The interval unit is **blocks**, as requested;
for a grayscale JPEG each block is one MCU. An interleaved multi-component
JPEG needs MCU-aware grouping outside this module; arbitrary block-count
restarts are not a claim of valid restart placement for every sampling mode.

Input fields are s_code[15:0], s_code_bits[4:0], s_amplitude[15:0],
s_amplitude_bits[4:0], s_block_end, s_scan_last, s_valid/s_ready. Code and
amplitude are right-aligned; code length must be 1..16, amplitude length
0..11, and unused upper bits must be zero. The module assumes a legitimate
upstream baseline Huffman codebook; it cannot detect an invalid prefix tree
from isolated already-encoded tokens. `s_block_end` marks the last symbol
of a block. `s_scan_last` must be exactly true on the last token of the
configured final block, and false elsewhere. It is independently checked
against block count. No empty block or code-less standalone flush token is
accepted through this interface.

Ordinary block ends do **not** pad or flush. The last token of a restart or
final block is sent to the bitpacker with flush set, causing one-bit padding
up to byte alignment. The controller waits for flush_done, which follows
acceptance of all entropy bytes including any FF00 stuffing. If this was a
nonfinal restart boundary, it then emits raw FF followed by D0..D7 and wraps
RST7 back to RST0. These two bytes bypass the entropy bitpacker and are
**never stuffed**. The final block never emits an extra restart marker.

Output m_data[7:0], m_valid/m_ready is the actual byte stream. `m_marker`
is metadata true on both raw restart bytes; it is not a request for a caller
to generate or stuff them again. `m_scan_last` is true on the final entropy
flush's final output byte (including a final stuffed zero when necessary),
and false at intermediate restart flushes and restart markers. Ultimately
use `scan_done`, rather than assuming a flush must produce an additional
byte: an already aligned bitstream need not gain a separate padding byte.

`predictor_reset_valid/predictor_reset_ready` is a held event at scan start
and after both bytes of every restart marker have drained. No next-block
token is accepted until this event is acknowledged. The caller must reset
all component DC predictors there. It must also prevent **upstream DC
symbol generation** from running ahead across that boundary: holding only
the already-encoded token is too late to correct a previously computed DC
difference. The event itself does not encode data or emit another RST.

## Flow, completion and errors

All transfers and events are `ce && valid && ready`. CE=0 freezes state,
byte payload and pending event; valid may remain high. Input/start ready
are low during pause. m_valid and the predictor event remain asserted under
backpressure. A busy start/config mutation is ignored. Counters
`blocks_completed` and `restarts_emitted` count accepted end tokens and
fully drained RST markers, respectively. No scan can restart until its prior
result drains.

`scan_done` is held until `scan_done_ready`, with stable `error_code`:

| code | cause |
|---:|---|
| 0 | final entropy flush fully drained |
| 1 | total_blocks=0 |
| 2 | illegal input bit length/value or scan-last metadata |
| 3 | defensive report of underlying bitpacker input_error |
| 4 | explicit abort |

An invalid token is consumed when s_ready, but is not forwarded to the
bitpacker. Errors and abort clear its pending bits/bytes and produce a held
result. Earlier externally transferred bytes cannot be revoked: a caller
must discard the failed scan. Abort is sampled on an enabled clock and
cancels a pending byte or predictor event; a scan result already pending is
preserved. A held-high abort advances through error-clear to DONE rather than
restarting the clear state. During CE=0, abort preserves a stalled valid byte
until the next enabled cancellation edge. Abort while idle does nothing. There is no implicit timeout:
a stalled consumer or missing block-end can wait indefinitely until abort.
The controller cannot infer coefficient count from Huffman tokens; an upstream
symbolizer must validate 64 coefficients per block.

Active-high synchronous rst overrides CE, clears the controller and its
bitpacker dependency, discards a partial scan and clears diagnostics. The
existing packer has an asynchronous reset internally; this wrapper drives
that reset during top reset, idle and error-clear states. Output/start/input
valid/ready paths are suppressed during reset.

## Verification and resources

```
python -B cores/system/common_scaffold/dsp/jpeg_scan_control/test_scan_control.py
python -B cores/system/common_scaffold/dsp/jpeg_scan_control/synth_scan_control.py
```

An independent Python canonical-code generator supplies a prefix-valid code
of each length 1..16. The oracle concatenates raw bit lists **across block
ends**, pads only on true boundaries, byte-stuffs FF, and inserts raw RST
pairs. Seven cases total 47 blocks and compare 294 output bytes exactly:
intervals 0,1,2,3 and >total; nondividing intervals; FF stuffing; RST7 rollover;
final-byte markers; initial and restart predictor events. SV adds random
input gaps, CE pauses, byte and predictor backpressure, held-payload checks,
busy-config mutation, zero-block and bit/metadata errors, defensive packer
fault injection, held-high abort through completion, CE-low abort preserving
a stalled byte, and reset of partial streams. Temporary binaries and
fixtures are automatically deleted; small JSON summaries remain here.

Isolated flattened synth_gowin, **including the existing bitpacker**:
1360 LUT1-4, 203 ALU, 258 FF, 155 MUX2_LUT5, 0 DSP/RAM.
No P&R, timing closure, board or complete JPEG container claim is made.

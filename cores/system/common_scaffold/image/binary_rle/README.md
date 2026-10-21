# Binary image run-length encoder and decoder

`binary_rle_encoder` and `binary_rle_decoder` provide a lossless streaming binary
mask codec. They use explicit row coordinates and canonical maximal runs,
distinct from the existing byte-stream literal/repeat `ips_rle_codec`.
WIDTH/HEIGHT are static integers1–65535. There is no image RAM or DSP.

## Token and interfaces

Both modules use clk, synchronous active-high rst and shared ce. Every transfer
requires ce && valid && ready. Define XW=max(1,ceil(log2(WIDTH))),
YW=max(1,ceil(log2(HEIGHT))), LW=ceil(log2(WIDTH+1)). Length is the actual
positive pixel count, not length minus one, so a complete65535-pixel run fits.

| Token field | Width | Meaning |
|---|---:|---|
| value | 1 | Run's binary mask value |
| start_x | XW | First pixel's zero-based column |
| y | YW | Zero-based row |
| length | LW | Consecutive pixels in this row,1 through WIDTH |
| sof | 1 | Exactly the first token, at (0,0) |
| eol | 1 | Run ends at WIDTH |
| last | 1 | EOL of row HEIGHT-1 |

Encoder input is s_value/s_valid/s_ready/s_sof/s_eol. Token outputs use m_ prefixes:
m_value, m_start_x, m_y, m_length, m_sof/m_eol/m_last, m_valid/m_ready.
Decoder input has the identical fields with s_ prefixes, so the encoder's
token interface directly wires to the decoder. Decoded output is m_value,
m_x/m_y, m_sof/m_eol/m_last with m_valid/m_ready. Each has done_valid/done_ready
and busy. Encoder status is frame_error; decoder status is error[5:0].
These are parallel hardware fields, not a specified byte/bit serialization.

## Canonical encoding and lossless expansion

For each row independently, the encoder emits every maximal contiguous run
of equal values, in increasing column order; rows follow raster order. Runs
never cross row boundaries even if adjacent rows have the same value. No run
splits at a smaller count limit. A single transition pixel is retained while
the preceding run waits for downstream acceptance. At a final-column value
transition, the old run and final singleton are both emitted correctly.
An all-constant row produces one token. A width1 row produces one singleton.

The decoder accepts the next token only after the current token has fully
expanded. It emits exactly length pixels with raster coordinates and rebuilt
SOF/EOL/LAST. Tokens must cover every pixel exactly once, consecutively from
(0,0), without gaps, overlaps or row skips. Adjacent runs in the same row must
have opposite values; equal values across different rows are permitted.
Thus valid accepted tokens have a unique canonical expansion and round-trip
encoding preserves every input pixel exactly.

## Errors and recovery

Encoder verifies source SOF only at the first pixel and EOL at each last-column
pixel, using fixed geometry. Bad markers latch frame_error, while the entire
frame still produces canonical tokens with geometry-derived output markers.
Downstream must discard that frame on encoder frame_error. Decoder cannot
infer the encoder's source-framing flag from canonical token fields, so retain
that status separately when composing a pipeline. Missing source pixels wait
for remaining input or reset; markers alone cannot infer lost transfers.

Decoder validates a token before emitting any pixel from it. Error bits are
independent and may combine:

| Bit | Condition |
|---:|---|
| 0 | length=0 |
| 1 | start_x/y differ from the next expected coverage coordinate |
| 2 | start_x+length exceeds WIDTH |
| 3 | SOF/EOL/LAST disagree with token geometry |
| 4 | start_x>=WIDTH or y>=HEIGHT |
| 5 | Same value as the preceding token in this row: nonmaximal encoding |

Any nonzero error rejects that entire token and immediately enters held DONE
with s_ready/m_valid low. Earlier valid pixels may already have transferred;
the consumer must discard the whole erroneous frame. No rollback/framebuffer
is implied. After reading the error, the caller discards any remaining tokens
of the rejected frame and acknowledges done_ready. Decoder then clears error
and expects a fresh frame beginning at (0,0) with SOF. It does not scan unknown
input for a resynchronization marker. A missing token without an explicit bad
transfer waits indefinitely until input or reset; there is no timeout.

Normal DONE follows final-token acceptance in the encoder and final-pixel
acceptance in the decoder. DONE/status remain held until done_ready. Encoder
frame_error clears on the next frame's first accepted source pixel; decoder
error clears on acknowledgement. All valid payloads remain stable during CE
pause/backpressure. Reset overrides CE, cancels buffered runs/pixels and clears
status/counters so fresh input can start immediately. Payload outside valid
is unspecified. busy covers partial frames and in-flight/DONE states.

## Storage, widths and throughput

Only counters and one transition pixel are buffered. There is no frame/line
memory, asynchronous RAM or host-computed token datapath. Run counters represent
WIDTH exactly, and end checks use LW+1 guard bits, covering start+length even
for the largest representable fields. Geometry is counted by x/y independently,
without multiplying WIDTH*HEIGHT in RTL, so maximum legal height and width
remain representable. Invalid geometry is rejected at elaboration/simulation.

The decoder can emit one pixel per enabled clock while a token is expanding.
The encoder collects same-value input one pixel per enabled clock; transitions
and row ends pause input while tokens are sent. Backpressure propagates through
the real encoder/decoder link; no unlimited buffering or worst-case compression
gain is claimed. Checkerboard masks expand into many coordinate-bearing tokens.

## Validation

```
python -B cores/system/common_scaffold/image/binary_rle/test_binary_rle.py
python -B cores/system/common_scaffold/image/binary_rle/synth_binary_rle.py
```

Seven profiles/63 frames PASS:631845 actual RTL encoder-to-decoder round-trip
pixels and115196 exact canonical tokens. The decoder receives **live encoder
RTL outputs**, not a replay of expected tokens. Independent Python row-run
enumeration checks every token and every decoded pixel/coordinate/marker.
Coverage includes1x1, single rows/columns, multirow, width257/4096/65535,
one-pixel and65535-pixel runs, all-zero/all-one, checkerboard, stripes, random,
islands, final-column transitions, CE/input gaps/backpressure, held DONE,
source SOF/EOL errors with subsequent recovery, and CE-low reset while both
buffered encoding and decoded output are pending.

Thirteen targeted malformed-token cases verify exact error masks and zero
expansion of rejected tokens, including length0/overlong, gaps/overlaps/wrong
row, bad SOF/EOL/LAST, coordinate ranges and nonmaximal runs. Every fault is
followed by a complete valid recovery frame, including equal-valued consecutive
rows:216 valid prefix/recovery pixels are checked. Eight invalid static
module/geometry combinations are rejected. Tests generate all hex/binaries
inside TemporaryDirectory and clean them; only compact JSON evidence persists.

Isolated synth_gowin and CHECK PASS for both cores and both geometry profiles:

| Top / geometry | LUT1–4 | LUT5 mux | ALU | FF | RAM | DSP |
|---|---:|---:|---:|---:|---:|---:|
| Encoder32x32 | 59 | 5 | 22 | 44 | 0 | 0 |
| Encoder65535x65535 | 150 | 4 | 64 | 120 | 0 | 0 |
| Decoder32x32 | 86 | 2 | 23 | 38 | 0 | 0 |
| Decoder65535x65535 | 193 | 8 | 97 | 93 | 0 | 0 |

No timing closure, integrated budget, board or application acceptance is claimed.

## Public design reference

Successfully accessed2026-10-19:
https://learn.microsoft.com/en-us/windows/win32/gdi/bitmap-compression
Microsoft documents run-length bitmap count/value encoding and explicit
end-of-line/end-of-bitmap controls. That public specification informed the
separation of count/value from row/frame boundaries. No implementation code
was copied. This binary image token protocol is independently defined above;
it is not BMP BI_RLE8/BI_RLE4, TIFF PackBits or the repository byte-stream codec.

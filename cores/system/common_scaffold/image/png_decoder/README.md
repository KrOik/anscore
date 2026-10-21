# PNG byte-stream decoder

Original synthesizable `png_decoder.sv` decodes noninterlaced PNG depth8, color type0 (grayscale) and2 (RGB). It implements all five scanline filters, zlib stored/fixed/dynamic DEFLATE blocks, canonical Huffman trees, every valid length/distance pair and overlapping LZ77 copies through a synchronous32KiB dictionary. Grayscale output is replicated to `{R,G,B}`. RGB is emitted unchanged in channel order. Indexed, alpha, other depths and interlace fail explicitly; they are not silently converted or reported as success.

## Interface and limits

Parameters are MAX_WIDTH=16, MAX_HEIGHT=12, MAX_COMPRESSED_BYTES=4096 by default. Geometry bounds are1..256 per axis; compressed capacity16..8192 bytes. START has no runtime configuration: IHDR provides the actual frame width/height/color type, returned on image_width[15:0], image_height[15:0], image_color_type[7:0]. Hold start_valid until start_ready. Input s_data[7:0]/s_valid/s_ready/s_last carries exactly one complete PNG, with s_last on the final IEND CRC byte only. Output m_rgb[23:0]/m_valid/m_ready and m_sof/m_eol/m_last describes the raster. Acknowledge terminal done_valid with done_ready; frame_error/error_code hold with DONE. Reset is synchronous active-low and overrides CE. Abort suppresses input/output immediately and terminates on an enabled edge; hold it through that edge. All transfers require CE. Output data/markers and terminal status hold across backpressure and CE pauses. After acknowledged success/error a new START works without reset.

Only the concatenated IDAT payload, including zlib framing, occupies compressed RAM. The parser first consumes and checks the complete PNG, including every chunk CRC, then inflates its bounded IDAT buffer. Arbitrary larger ancillary chunks are streamed and discarded without buffering. Capacity overflow fails; no overwrite or host-predecoded pixel substitution occurs. The32KiB dictionary and compressed/scanline/Huffman memories are synchronous. The output reconstruction uses one reused scanline RAM and three left/upper-left channel registers. Every filtered raw byte enters dictionary and Adler before reconstruction, including filter selectors; only reconstructed bytes enter the row RAM. Original compressed input is never treated as pixels.

This is a resource-oriented serialized decoder. Huffman code lookup scans its small synchronous table bit by bit; no video-rate or throughput target is claimed. Some legal256×256 images exceed the configured compressed capacity; geometry support is independent of compressed-size support.

## Container, DEFLATE and validity

Signature, first/unique13-byte IHDR, geometry, method, consecutive IDAT ordering and zero-length terminal IEND are checked. Multiple/empty IDAT chunks can split zlib headers and block boundaries arbitrarily. CRC32 covers each chunk type+data. PNG chunk names must be alphabetic with the reserved bit clear; chunk lengths must be below2^31. Unknown critical chunks fail. RGB optional PLTE is accepted only before IDAT, once, with1..256 complete entries; grayscale PLTE fails. Unknown ancillary chunks are CRC checked then ignored; this is not a claim to validate every ancillary chunk's internal semantics, metadata ordering or color management.

Zlib requires CM8, CINFO<=7, correct FCHECK, and no preset dictionary. Backreferences must fit both available history and the advertised CINFO window. Stored blocks validate LEN/NLEN. Dynamic trees enforce canonical oversubscription and completeness rules, permitting the single-symbol length1 exception for literal/distance and an empty distance tree only when unused. HLIT<=286 and HDIST<=30 follow mature zlib's accepted table bounds; field encodings for31/32 distance entries are deliberately rejected, even if reserved symbols would be unused. Code-length repeat16/17/18 bounds and previous-symbol requirements are checked. Reserved literal286/287 and distance30/31 cannot decode successfully. Distance1 overlap, distance32768, dictionary wrap, multiple blocks and final byte alignment are implemented. Final decoded byte count, raster completion, exactly four remaining Adler bytes and Adler32 must all agree.

**Pixels are provisional until successful DONE.** PNG CRCs are checked before the first pixel, but final Adler32 is checked after pixels may already have been accepted. Any error/abort invalidates the entire frame, including its previously emitted pixels. Consumers needing atomic visibility must buffer or otherwise discard a failed frame. A source stopping without s_last or a complete PNG must abort/reset; no input watchdog is provided.

Error codes (hex):10 signature;11 early/missing PNG end marker;12 chunk structure/order/length/type;13 unsupported critical chunk;14 compressed capacity;15 PNG CRC;16 dimensions;17 unsupported IHDR format/method;20 zlib header;21 truncated bit input;22 reserved block type;23 stored LEN/NLEN;24 invalid Huffman tree;25 dynamic header/repeat bounds;26 invalid Huffman symbol code;27 reserved literal/length;28 reserved distance;29 invalid history/window distance;30 excess decoded bytes;31 invalid scanline filter;32 incomplete raster/zlib tail;33 Adler;F0 abort;FF internal state.

## Reproduce and evidence

Run from repository root:

```
python -B cores/system/common_scaffold/image/png_decoder/run_tests.py
python -B cores/system/common_scaffold/image/png_decoder/test_deflate_limits.py
python -B cores/system/common_scaffold/image/png_decoder/test_errors.py
python -B cores/system/common_scaffold/image/png_decoder/test_protocol.py
python -B cores/system/common_scaffold/image/png_decoder/test_numeric_limits.py
python -B cores/system/common_scaffold/image/png_decoder/run_synthesis.py
```

All vector generation is tracked Python; tests require NumPy/Pillow/zlib and no network. Main20 files/1494 pixels cover gray/RGB,1×1,7×5,16×12, all5 filters, actual zlib BTYPE0/1/2, multiple blocks and7-byte IDAT splits. Python independently computes filtered bytes from original pixels; Pillow actually opens and checks every generated image. Two additional main files are written by Pillow's real PNG encoder, then decoded in RTL.

Specification-driven bit fixtures are first accepted by Python zlib.decompress, then sent through RTL: a dynamic HLIT286/HDIST30 tree explicitly using all16/17/18 repeat symbols, and a255×129 image exercising distance1 overlapping copies, distance32768 and dictionary wrap. These add2 files/32896 pixels.

Error regression has32 malformed files, each immediately followed by a healthy2×2 frame without reset: PNG/IHDR/IDAT/ancillary CRC, Adler, unsupported formats, high-bit length, reserved chunk bit, PLTE legality, IDAT ordering, invalid filter/byte count, LEN/NLEN, HLIT288, HDIST31/32, incomplete/oversubscribed Huffman, reserved symbols and impossible distance. It verifies the explicit error code and32 healthy recoveries/128 pixels; expected values are not modified to conceal malformed outputs.

Protocol regression aborts all54 active state values (excluding only IDLE/DONE), plus CE-low reset at10 parser/table/copy/filter/checksum/output phases; each is followed by a healthy7×5 frame, totaling64 recoveries/2240 pixels. It checks token stability, markers, held DONE and no acceptance during abort/reset. Numeric limits add5 valid files/12693 pixels:256-wide RGB,256-high grayscale, compressed lengths **exactly4096 and8192**, optional RGB PLTE+ancillary. Two errors prove8203-byte overflow and a CINFO256 stream attempting a32768-byte distance; four illegal static specializations fail at time zero.

Total successful outputs across the five suites:123 frames,49451 pixels. JSON evidence binds the current RTL SHA; source and evidence hashes are frozen separately. Temporary vectors, binaries and downloaded source live in TemporaryDirectory and are removed; retained logs are compact acceptance evidence.

## Resources and references

Isolated `synth_gowin -noalu -nodsp; check -assert; stat`:

| Profile | LUT class including ALU/MUX and4×RAM16SDP4 | FF | DSP | RAM primitives | Conservative BRAM9 |
| --- | ---: | ---: | ---: | --- | ---: |
| Default16×12/4096 |4677|928|0|19DPB+1DPX9B+1SPX9|42|
| Max256×256/8192 |4675|934|0|21DPB+1DPX9B+1SPX9|46|

The conservative convention counts every Gowin block primitive as two9Kb units, including SPX9/DPX9B. These are isolated synthesis results, not place/route, timing closure or board qualification. No JTAG/UART/board acceptance source was modified.

PNG specification, RFC1950/1951 and mature miniz_tinfl C source were actually downloaded for structure/checksum/Huffman/LZ77 review; exact URLs, SHA256 and excerpts are in references.json. No third-party source is copied into RTL. Optional fetch_references.py refreshes provenance using temporary downloads. Executed numerical references are Python zlib and Pillow, not a claimed bit-identical port of miniz. Original algorithms and tests are independently written.

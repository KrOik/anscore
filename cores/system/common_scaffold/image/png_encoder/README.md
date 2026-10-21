# Complete streaming PNG8 encoder

Original RTL emits a complete, standard PNG file directly from gray8 or RGB8 pixel input. It produces the PNG signature, IHDR, one complete IDAT chunk and IEND, with each required length and CRC32. IDAT contains a valid `78 01` zlib header, real DEFLATE stored blocks with LEN/NLEN and BFINAL, raw filtered scanlines and Adler32. There is no host file assembly, checksum injection or precomputed compressed data.

Stored DEFLATE is a standards-defined lossless encoding method. It offers **no compression-ratio benefit**: pixels plus filter bytes and block/container overhead are emitted verbatim. It is a complete working format encoder, not an LZ77/Huffman compression implementation. Filter type None (zero) is emitted before every scanline; color types0 and2, depth8, noninterlaced, no palette, transparency, metadata or APNG.

## Ports and frame contract

Parameters WIDTH/HEIGHT are static 1..4096; default16x12. `cfg_mode[1:0]` is captured atomically at the `start_valid && start_ready` transfer: 0=gray8, 1=RGB8; 2/3 report explicit errors. Input `s_pixel[23:0]` is `{R,G,B}` in RGB mode; gray mode uses the low8 bits and ignores upper16. One accepted input pixel carries `s_sof` at pixel0, `s_eol` on each row end and `s_last` only on the final pixel. Wrong markers terminate the command with error.

Byte output `m_data[7:0]` has ordinary valid/ready. `m_sof` marks signature byte0 and `m_last` marks only the final IEND CRC byte. Data/markers remain stable across output backpressure and CE pauses. START/input/output/DONE transfers all require CE=1; output valid and DONE remain asserted when CE=0. Successful DONE cannot occur before the final byte is accepted. `output_bytes[31:0]` counts accepted file bytes and is held through DONE. Arbitrary input gaps are allowed. Processing is bounded by available pixels and sink acceptance; no internal timeout substitutes for missing input.

Reset is synchronous active-low and takes priority over CE. Abort suppresses byte valid/input ready immediately and latches error on the next enabled edge. Late abort in DONE preserves the held result. After DONE acknowledgement the next START fully resets checksums, counters, format state and buffered-pixel validity. On marker error or abort, previously emitted bytes form a **partial invalid file**: consumers must discard that frame; bytes cannot be rolled back on a streaming interface. Error codes: 0x80 invalid static dimensions, 0x81 input frame markers, 0x82 unsupported runtime mode, 0x93 abort, 0x94 unsupported internal state.

## Hardware and size accounting

One pixel register, no frame/line RAM, DSP, variable multiplier or variable divider. Output logic updates CRC32 per accepted chunk byte and modulo65521 Adler components per accepted raw scanline byte. CRC uses the standard reflected0xEDB88320 polynomial and final complement; chunk checksums cover type+data only, with big-endian CRC fields. Adler covers decompressed filter+sample bytes only, serialized big-endian B then A.

Let C be1 or3, R=H*(W*C+1), and B=ceil(R/65535). IDAT length is `R+5*B+6`; complete file size is `R+5*B+63`. Every stored block has at most65535 raw bytes, including row-filter bytes. Block boundaries may split a scanline or RGB pixel; buffered pixel/channel state is preserved. All block headers start on byte boundaries. No extra empty block is emitted for exact multiples of65535.

The maximum static geometry4096x4096 RGB yields R=50335744 and IDAT length50339595, below PNG's signed31-bit chunk-length ceiling. A/B sums use explicit17-bit carry and one modular subtraction, CRC32 is independent, and output/raw counters are32-bit. Isolated `synth_gowin -nodsp; check -assert` maps default16x12 to812 LUT-class and cross-block257x173 to827 LUT-class, each0DSP/0BRAM. LUT accounting includes ALU/MUX and RAM16SDP4*4. This is synthesis-only resource evidence, not physical timing or board qualification.

## Validation

Run from repository root:

```
python -B cores/system/common_scaffold/image/png_encoder/run_tests.py
python -B cores/system/common_scaffold/image/png_encoder/test_numeric_limits.py
python -B cores/system/common_scaffold/image/png_encoder/test_protocol.py
python -B cores/system/common_scaffold/image/png_encoder/test_parameters.py
python -B cores/system/common_scaffold/image/png_encoder/synth.py
```

The main regression passes23 cases /46 frames /353850 input pixels. The independent byte oracle constructs scanlines/chunks from format definitions using Python struct and zlib checksums, not an RTL state model. Every actual RTL-generated file is separately decoded by real Pillow12.3.0 and zlib1.3.1, with exact input pixel equality, valid stream termination, every chunk CRC and Adler checked. Actual stored LEN/NLEN/BFINAL fields are parsed independently. Tested raw sizes65535,65536 and133556 exercise block lengths `[65535]`, `[65535,1]` and `[65535,65535,2486]`; the RGB case splits a pixel across a stored-block boundary. Geometries include1x1, thin, odd and default; constants, random RGB/gray and repeated255 check checksum wraps. Additional numeric cases cover legal maximum single-axis4096 and large all255 data. Each functional case repeats two frames, perturbs cfg_mode after START, inserts CE pauses and independent source/sink stalls, and holds DONE.

Protocol covers abort in all15 active output stages, six marker faults, both invalid modes, gray/RGB changes between commands, final-byte backpressure and CE-disabled reset during a buffered RGB pixel, with25 successful recovery frames. Four invalid dimension specializations report0x80. All evidence binds the current RTL SHA256. Tests use TemporaryDirectory; simulation dumps and generated PNGs are deleted after validation. No JTAG, serial or shared registry was touched.

W3C PNG3 and actual zlib1.3.1 stored-block source were fetched and inspected; exact URL/hash/provenance and representation differences are in references.json. A file generated by Pillow.save may use different filters, block lengths and Huffman coding and need not be byte-identical. Our output is independently confirmed standards-readable and pixel-lossless. PNG encoder-to-decoder system integration is separately owned and is not claimed by this isolated module report.

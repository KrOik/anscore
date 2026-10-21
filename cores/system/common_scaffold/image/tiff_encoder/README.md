# Streaming TIFF 6.0 encoder

Real synthesizable full-file encoder; no host-generated headers or per-file constants.
Uncompressed baseline TIFF: grayscale unsigned 8/16-bit and chunky RGB8, runtime II/MM
byte order. Orientation is top-left, PhotometricInterpretation is BlackIsZero/RGB,
Compression=1 and PlanarConfiguration=1. It emits one image, no compression,
alpha, palettes, tiled images, multipage IFDs, floating point or BigTIFF.

## Interface

`tiff_encoder #(WIDTH=16, HEIGHT=12, ROWS_PER_STRIP=4)`.
All three static parameters must be 1..4096. More strip rows than image rows is
legal. Runtime `cfg_mode`: 0 gray8, 1 gray16, 2 RGB8, 3 invalid.
`cfg_big_endian`: 0 II, 1 MM. Both configuration fields snapshot on accepted START.
`s_pixel[31:0]`: grayscale in low 8/16 bits, RGB in bits 23:0 as RRGGBB.
Ignored upper bits do not affect encoding. Grayscale16 preserves all 16 bits;
RGB component order is RGB for both endiannesses.

Every transfer requires `ce && valid && ready`; ready/valid are not gated with
CE, so a disabled CE freezes all state and bytes. Asynchronous combinational
ready indicates state capacity only. `rst_n` is synchronous active-low and
overrides CE. START is accepted only in IDLE; DONE is held until its handshake.
`abort` has priority over transfers in active states and reports error 3; the
receiver must discard any partial file. Reset also discards a partial file.
Abort in IDLE/DONE is ignored. `s_sof`, `s_eol`, `s_last` must identify exactly
the first pixel, each final pixel of a row and the final image pixel. Bad markers
end the job with error 4. Parameter error is 1 and invalid mode is 2.
On DONE `frame_error == (error_code != 0)`. `output_bytes` counts only actual
accepted byte transfers, including partial files; it resets on next START.
Output `m_sof` identifies byte zero, `m_last` the final image-data byte.

Metadata is serialized first, so upstream pixels must obey ready while headers
are emitted. One input pixel register feeds 1/2/3 byte transfers. There is a
one-cycle inter-pixel refill gap; this core makes no one-pixel-per-clock claim.
All valid output bytes/markers are stable through CE disable and backpressure.
Error/abort terminates the job without fabricating a final-byte marker.

## TIFF structure

Eight-byte header, one 11-entry sorted IFD at offset 8, zero next-IFD pointer,
RGB BitsPerSample vector at offset 146, strip offset/count arrays at 152 and
152+4*N, image bytes at 152+8*N. N=ceil(HEIGHT/ROWS_PER_STRIP).
For a single strip the TIFF value fields directly contain its offset/count;
reserved auxiliary arrays are legal unreferenced padding. SHORT values fit in
the first two bytes of each value field in either byte order, never right-aligned.
Final strip count uses only remaining rows. Pixel strip boundaries require no
padding (TIFF strip data need not have even size). Every referenced IFD/value
array offset is word aligned. Maximum declared geometry fits 32-bit TIFF offsets.

## Verification

```
python -B cores/system/common_scaffold/image/tiff_encoder/run_tests.py
python -B cores/system/common_scaffold/image/tiff_encoder/test_protocol.py
python -B cores/system/common_scaffold/image/tiff_encoder/test_parameters.py
python -B cores/system/common_scaffold/image/tiff_encoder/synth.py
```

Main suite executes actual RTL, compares every complete file byte with a
declarative `struct.pack` TIFF oracle, and independently opens those exact output
bytes using both Pillow and tifffile/NumPy. Thirty files cover five geometries
(1x1, 7x5, 16x12, 64x32, 4096x1), all three modes, both endian orders, partial
last strips and strips larger than the frame. Gray16 includes 0,1,255,256,32768,
65535. Each simulation inserts CE stalls and output backpressure, changes runtime
configuration after START, checks byte hold, SOF/EOF, byte count and held DONE.
Protocol suite covers six marker errors, bad mode, abort during metadata,
pixel wait and byte emission, synchronous reset with CE=0 and healthy recovery:
18 recovery frames, 14 explicit errors. Parameter suite checks six invalid
static profiles. TemporaryDirectory removes simulations and complete image files.

Isolated `synth_gowin -nodsp; check -assert`: 16x12/strip4 uses 1476 LUT-class,
0 DSP, 0 conservative BRAM9; 64x32/strip7 uses 1635 LUT-class, 0 DSP, 0 BRAM9.
LUT-class includes LUT/ALU/MUX and four per RAM16SDP4; every block RAM counts
twice in BRAM9 units. This is synthesis evidence, not routed timing or board
validation. Source-bound JSON evidence and log hashes are retained.

`references.json` records actually fetched TIFF 6.0 specification and mature
libtiff/Pillow source URLs, SHA256, sizes and excerpts. Network payloads are held
only in memory. This implementation is original RTL, not copied source code.

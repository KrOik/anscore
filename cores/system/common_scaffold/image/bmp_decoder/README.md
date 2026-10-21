# BMP24 decoder

`bmp_decoder.sv` is a complete-file BMP24 BI_RGB decoder, with a synchronous RGB frame RAM. Input is an 8-bit BMP file stream; output is RGB888 in top-down raster order regardless of the signed BMP height. Implemented independently after a repository search found no existing BMP decoder.

Supported format: BM signature, 14-byte file header, exactly 40-byte BITMAPINFOHEADER, planes=1, 24 bits/pixel, compression=BI_RGB. Positive heights store bottom-up rows; negative heights store top-down rows. Any legal pixel offset >=54 is supported, including skipped application data; all four DWORD row padding cases and arbitrary padding bytes are handled. Declared trailing file bytes are consumed and ignored. biSizeImage may be zero or exactly padded raster size. Resolution/color-use metadata is ignored. Paletted, bitfield, RLE, 16/32-bit, extended DIB and embedded JPEG/PNG formats are explicitly rejected.

Interface: `start_valid/start_ready` begins a file; `s_data/s_valid/s_ready/s_last` transfers bytes; final `s_last` must coincide with bfSize. `m_rgb/m_valid/m_ready/m_sof/m_eol/m_last` transfers decoded raster pixels with first/row-end/frame-end flags. `image_width/height` describe accepted geometry. All handshakes require `ce=1`; data and state freeze at CE=0. Active-low synchronous reset operates regardless of CE. `abort` at CE=1 terminates active operations with error; abort is ignored in IDLE/DONE. `done_valid` and error remain asserted until CE-qualified `done_ready`; start is accepted only in IDLE. Output data/flags remain stable while stalled. The entire input must pass validation before output begins; on abort discard the transaction, including any pixels already emitted.

Error codes: 01 truncated header; 02 signature/reserved/DIB/planes/depth/compression; 03 dimensions; 04 offset/size/raster overflow; 05 early s_last; 06 missing s_last at bfSize; 07 internal invalid state; 08 abort; 09 static parameter bounds.

Parameters default MAX_WIDTH=64, MAX_HEIGHT=64; each is legal 1..256. Maximum legal 256x256 is functionally tested but does not imply target fit. Only 64x64 and 128x64 are synthesized resource profiles. Default: 5475 LUT-class, 0 DSP, 12 conservative BRAM9; 128x64: 5492/0/24. Count LUT+ALU+MUX+4*RAM16SDP4 and every physical block RAM primitive times two. No place/route, timing or hardware acceptance is claimed.

Run from repository root:

```
python -B cores/system/common_scaffold/image/bmp_decoder/run_tests.py
python -B cores/system/common_scaffold/image/bmp_decoder/test_protocol.py
python -B cores/system/common_scaffold/image/bmp_decoder/test_numeric_limits.py
python -B cores/system/common_scaffold/image/bmp_decoder/synth.py
```

Main tests decode actual Pillow-generated BMP bytes and independently compare RGB/markers: 12 successful files / 8396 pixels and 16 invalid files. Numeric tests include independently handcrafted BGR/nonzero-padding fixture, max geometry, signed overflow and static invalid profiles. Protocol tests observe/require all five active FSM states for abort and CE-off reset, force final-pixel backpressure, and recover healthy frames after errors. Reports bind exact RTL SHA256. Temporary compile files and reference downloads use TemporaryDirectory and are automatically removed; retained logs and JSON are evidence. `references.json` records retrieved Microsoft format definitions, URLs and content hashes; no third-party RTL was copied.

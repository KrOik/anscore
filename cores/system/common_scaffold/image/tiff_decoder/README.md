# TIFF baseline decoder

`tiff_decoder.sv` parses actual complete classic TIFF files entirely in RTL. A repository-wide search found no equivalent decoder. II and MM byte order, magic42, arbitrary IFD tag order, SHORT/LONG scalar geometry, inline/external SHORT BitsPerSample, inline/external SHORT/LONG strip-offset and byte-count arrays, multiple strips, partial final strips, and arbitrary physical strip order/gaps are supported. No host pre-parsing or tag-to-configuration shortcut is used. Logical raster output follows top-left chunky image coordinates.

Modes: `image_mode=0` gray8 in `m_pixel[7:0]`, `1` gray16 in `[15:0]`, `2` RGB888 in `[23:0]` RRGGBB. Unsigned gray8/16 BlackIsZero and WhiteIsZero (inverted to BlackIsZero output), and RGB8 photometric2 are supported. TIFF defaults Compression1, SamplesPerPixel1, RowsPerStrip unbounded, Orientation1, PlanarConfiguration1, SampleFormat1, and BitsPerSample1 are applied; unsupported effective formats are rejected. RGB permits equal8-bit BitsPerSample array or scalar8. StripByteCounts must equal exact uncompressed logical strip bytes. First IFD only; a nonzero next-IFD link is an explicit unsupported-format error.

Unsupported compression, palette, alpha/ExtraSamples, tiles, BigTIFF, predictors other than1, FillOrder other than1, signed/floating samples, other orientations, and planar images fail explicitly. Unknown ancillary tags are ignored; no ICC, transfer-function, resolution or other metadata color-management effect is claimed. Duplicate recognized mandatory/configuration tags fail; unsupported-type/count recognized tags fail. Bounds are checked before each synchronous byte-memory read, geometry calculation and strip range. Successful output can precede discovery of a malformed later strip: pixels are provisional until successful DONE, and consumers must discard the entire transaction on any error or abort.

`start_valid/start_ready` starts a file. CE-qualified `s_data/s_valid/s_ready/s_last` loads all bytes through the final byte; capacity overflow is explicit error. Parsing begins after s_last, using a synchronous byte RAM, then `m_pixel/m_valid/m_ready/m_sof/m_eol/m_last` emits raster pixels. `image_width/image_height/image_mode` describe output. Active-low synchronous reset works even at CE0. CE0 freezes state and output. Abort at CE1 terminates any active state with error09; idle/done ignore abort. Done/error are held until CE-qualified done_ready, after which start can be accepted again. A missing s_last before capacity is exhausted cannot be distinguished from an input pause: the host must eventually finish input or abort.

Error codes:01 header/signature/magic;02 dimensions;03 file-capacity overflow;04 file/IFD/strip bounds or byte-count mismatch;05 missing/duplicate/invalid-type/count required tag or strip-count mismatch;06 unsupported format;08 internal state;09 abort;0A static parameter error.

Defaults MAX_WIDTH16, MAX_HEIGHT12, MAX_FILE_BYTES4096. Legal static bounds geometry1..256 and file64..8192. File capacity independently limits achievable uncompressed frame size. Resources from isolated `synth_gowin -nodsp; check -assert`: default5301 LUT-class,0 DSP,4 conservative BRAM9; alternate32x24/4096=5336/0/4. Every physical block RAM primitive counts as2 BRAM9, including SP/SPX9; LUT-class=LUT+ALU+MUX+4*RAM16SDP4. These are synthesis results, with no routing, hold/timing or board claim.

Run from repository root:

```
python -B cores/system/common_scaffold/image/tiff_decoder/run_tests.py
python -B cores/system/common_scaffold/image/tiff_decoder/test_errors.py
python -B cores/system/common_scaffold/image/tiff_decoder/test_protocol.py
python -B cores/system/common_scaffold/image/tiff_decoder/test_numeric_limits.py
python -B cores/system/common_scaffold/image/tiff_decoder/synth.py
```

Main:55 successful files/1925 pixels, including3 actual Pillow-encoded and6 actual tifffile-encoded files plus independent handcrafted II/MM mixed strips and WhiteIsZero fixtures. Pillow exposes raw WhiteIsZero16 values or rejects MM WhiteIsZero16, so these fixtures use actual tifffile array reads with explicit photometric inversion. Errors:28 malformed files each followed by a healthy recovery (980 pixels). Protocol:25 active-state aborts and25 CE-off active-state resets, each followed by a healthy frame (1750 pixels). Numeric:12 good files/3016 pixels and5 errors, exact4096/8192 capacity,256-wide/tall edge geometry, static parameter bounds. Main/numeric vary CE and output backpressure and check pixel/marker stability while stalled. Every result binds exact RTL SHA256.

References actually fetched:TIFF6 specification PDF,libtiff directory reader,and Pillow TIFF plugin, with URLs, byte counts, SHA256 and excerpts in references.json. RTL is independently implemented. All compile/test/download products use TemporaryDirectory and are removed automatically; retained logs/JSON are evidence.

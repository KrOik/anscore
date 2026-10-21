# Color JPEG entropy scan

`jpeg_color_scan.sv` accepts actual unsigned 8-bit Y/Cb/Cr blocks and produces baseline sequential JPEG entropy bytes. The hierarchy contains the existing serial DCT, quantizer/zigzag, three-component DC predictor and symbolizer, default luminance/chrominance Huffman tables, bitpacker and scan controller. Host-generated coefficients are not required.

Transfers occur on `ce && valid && ready`; reset is synchronous active-low and takes priority over `ce`. Hold source data and metadata until accepted. Hold completion until `done_ready`; a late abort cannot change an already completed result.

Write all 64 natural-order nonzero entries for table 0 (Y) and table 1 (shared Cb/Cr), then assert `cfg_valid`. Successful commit pulses `cfg_done`; incomplete or zero-valued tables pulse `cfg_error` and retain the prior active tables. Each successful commit clears the written bitmap. Writes/commits are accepted only while idle. Configuration has priority over start. Before each block, the selected active table is synchronously reloaded into the quantizer.

On a start handshake, MCU count, restart interval and sampling are latched. Restart interval is in MCUs, with zero disabling restarts. Each block contains 64 raster-order samples. Component IDs are Y=0, Cb=1, Cr=2. Required MCU block order:

- 4:4:4: Y, Cb, Cr.
- 4:2:0: Y top-left, Y top-right, Y bottom-left, Y bottom-right, Cb, Cr.

`s_block_first` marks pixel 0, `s_block_last` pixel 63, and `s_frame_last` only the final pixel of the final block. Metadata is checked on every accepted sample. Restart markers align to MCU boundaries, wrap RST0..7, and reset all three DC predictors. A new successful scan resets predictors without requiring global reset.

The output is entropy scan data only: byte stuffing, restart markers and terminal padding are included; SOI/DQT/SOF/DHT/DRI/SOS/EOI headers, RGB conversion, chroma downsampling and frame rasterization are upstream/downstream responsibilities. `m_marker` identifies restart marker bytes; `m_scan_last` marks the terminal scan byte.

Errors are `81` malformed input metadata, `82` DCT saturation, `83` quantizer saturation/configuration error, `84` symbolizer error, `85` Huffman error, `86` abort and `87` invalid zero/overflowing MCU count. Underlying scan-controller errors occupy `01..0F`. Pipeline errors and abort are fail-stop: globally reset and reload tables before reuse. Invalid starts and configuration rejection are recoverable. An aborted stream is partial and must be discarded.

Run from the repository root:

```powershell
python -B cores/system/common_scaffold/dsp/jpeg_color_scan/test_color_scan.py
python -B cores/system/common_scaffold/dsp/jpeg_color_scan/test_errors.py
python -B cores/system/common_scaffold/dsp/jpeg_color_scan/synth.py
```

Numerical verification compares every byte and metadata flag against an independent integer DCT/quantization/entropy reference. Five fixtures replay twice without reset, covering 4:4:4/4:2:0, independent DC predictors, random pixels, restart intervals 0/1/2, RST wrap, backpressure, CE gaps, table rejection and held-DONE abort. Pillow decodes all streams with matching headers. Directed negative/reset tests cover malformed metadata, abort, invalid counts and reset at table/DCT/quantizer/output/DONE phases. Evidence JSON files record simulation results; `synthesis.json` and `synthesis.log` record full-hierarchy Gowin synthesis. Temporary simulation artifacts are automatically removed.

This serial composition prioritizes complete numerical behavior; it is not a pixel-per-cycle encoder. Quant-table reload and serial DCT/division add inter-block latency. Synthesis is not routed timing closure or hardware validation; this module has no board-pass claim.

External design references: libjpeg-turbo [jchuff.c](https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/src/jchuff.c) and [jcmaster.c](https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/src/jcmaster.c), for MCU restart alignment and component predictor conventions. Download hashes are in `reference.json`; no external implementation code was copied.

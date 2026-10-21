# Grayscale JFIF frame integration

`jpeg_gray_encoder` is a new integration top for existing library algorithms. It is not a new DCT, quantizer, entropy encoder, or color encoder. Dependencies are recorded with package-relative SHA256 values in `dependencies.json`.

The complete output is baseline sequential, single-component 8-bit JPEG: SOI, real APP0 JFIF 1.01, DQT, SOF0, default DHT, DRI, SOS, entropy-coded scan, EOI. Existing serial fixed-point DCT, quantization/zigzag, differential DC, AC run-length/Huffman, byte stuffing and restart control are reused unchanged. A complete frame RAM converts raster order into edge-replicated 8x8 blocks. This is a bounded-frame encoder, without a video throughput claim. Lossy decoded values need not equal input pixels.

Geometry is fixed at elaboration: WIDTH/HEIGHT 1..256, product at most 16384. Defaults are 16x16. Raster byte input requires SOF exactly at the first pixel and EOL exactly at each row end. Only WIDTH*HEIGHT pixels are accepted; extra input is blocked through entropy, stalled EOI and completion. Success acknowledgement allows the next frame without reset. No pixel may be sent before start is accepted.

All transfers, including output and done acknowledgements, require CE=1 in addition to valid/ready. CE=0 freezes state and held outputs. Reset is active-low: wrapper and scan are synchronous; reused raster has asynchronous reset. Load all 64 natural-order nonzero quantization entries, then handshake cfg_valid. cfg_done reports completion and cfg_error reports rejection. Both submodules receive identical table transfers and configuration; rejected zero tables preserve the previous active table/restart interval. Update shadow entries and commit again to repair. Tables and cfg are accepted only while idle; configuration takes priority over table writes. Start requires a successful prior configuration.

Runtime errors: 0x91 header command, 0x92 raster SOF/EOL protocol, 0x93 abort, 0x94 illegal wrapper state; existing scan codes 0x81..0x86 are propagated. Abort during header/APP0/scan/EOI terminates with error. Partial output must be discarded. Errors hold done until acknowledgement, then lock until reset and quantization reload/configuration. Busy includes configuration, successful completion pending acknowledgement, and locked failure.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/jpeg_gray_encoder/test_frame.py
python -B cores/system/common_scaffold/image/jpeg_gray_encoder/test_errors.py
python -B cores/system/common_scaffold/image/jpeg_gray_encoder/test_configuration.py
python -B cores/system/common_scaffold/image/jpeg_gray_encoder/test_boundaries.py
python -B cores/system/common_scaffold/image/jpeg_gray_encoder/synth.py
```

Tests use actual RTL JPEG output, Pillow independent decoding, exact independent Python entropy comparison, nonconstant random and gradient images, consecutive frames, CE/output stalls, malformed raster, aborts, atomic table updates/rejections and geometry limits. Synth reports include all ten RTL hierarchy dependencies; 8x8/13x9/256x64 use 5936/6077/5874 LUT-class cells, zero DSP and 2/2/18 conservative BRAM9. No place-and-route or physical board verification is claimed by this package. Temporary vectors/simulation/netlists are confined to auto-cleaned system temporary directories. Persistent small logs/evidence are retained for acceptance.

`references.json` records actual fetched libjpeg-turbo marker writer and license hashes. No external code was copied. Existing algorithms and contracts remain unchanged.

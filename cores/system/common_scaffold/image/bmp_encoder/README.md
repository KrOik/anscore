# BMP24 encoder

`bmp_encoder.sv` is a complete uncompressed BMP24 / BITMAPINFOHEADER encoder.
Input is top-to-bottom raster RGB888 (`s_pixel[23:16]=R`). Output includes the
14-byte file header, 40-byte DIB header, BGR pixels and zero padding to a
four-byte row boundary. All multibyte fields are little endian. `cfg_top_down`
is captured at START: 1 emits negative height and top-down rows; 0 emits
positive height and bottom-up rows. Input orientation never changes.

WIDTH/HEIGHT default to 16/12 and each legal range is 1..256. Every input pixel
is first written into synchronous frame RAM, allowing either output direction.
This costs 24*WIDTH*HEIGHT memory bits and adds a full-frame capture latency.
The 256-square functional boundary is not a claim that it fits the target FPGA.
Isolated synthesis reports cover 16x12 and 64x32 only. No board or timing claim.

All transfers, including START, pixel, output-byte and DONE, require rising
clock edge AND `ce && valid && ready`. Ready and valid can remain asserted
while CE is low. Synchronous active-low reset acts regardless of CE.
START is accepted only in IDLE; input frames require exactly one SOF on the
first pixel, EOL on every last pixel of a row and LAST on the final pixel.
Pixels are accepted only during capture. Output valid/data/SOF/LAST remain
stable under downstream stalls and CE pause. DONE occurs only after the final
byte has been consumed, holds until its handshake, and reports `output_bytes`.
SOF marks the file's first byte and LAST its final byte, including final padding.

Errors: 1 invalid static geometry, 2 active abort, 3 incorrect input markers,
4 internal state error. An error holds DONE until acknowledged; the next START
can capture a fresh frame. `abort` is CE-gated and has priority over normal
state transitions. Abort in IDLE or DONE is ignored. On an abort edge an
already presented output byte can be consumed; discard the entire transaction,
including any partial BMP, after any error or abort. A reset also cancels the
transaction. This interface cannot detect a truncated source which never
provides its remaining input pixels; host timeout/abort is required.

Run from the repository root:

```powershell
python -B cores/system/common_scaffold/image/bmp_encoder/run_tests.py
python -B cores/system/common_scaffold/image/bmp_encoder/test_protocol.py
python -B cores/system/common_scaffold/image/bmp_encoder/test_parameters.py
python -B cores/system/common_scaffold/image/bmp_encoder/synth.py
```

Functional tests cover both output directions, all four row-padding cases,
repeated transactions, input config capture, CE pauses, output backpressure,
random RGB/full-byte extrema and 256x256. Actual RTL output is compared against
a declarative `struct`-packed BMP oracle and independently decoded by Pillow.
Protocol tests exercise all six active states for abort, CE freeze and CE-off
reset, six malformed marker cases, recovery, terminal drain and DONE hold.
Four invalid static profiles explicitly return geometry error. Test binaries,
hex fixtures and actual BMP files live only in TemporaryDirectory and are
automatically cleaned. Source-bound JSON and synthesis logs remain as evidence.

References and downloaded-source SHA256 are in `references.json`. Standard
format logic is original RTL; no mature implementation code is copied.
No palette, RLE, alpha, bitfields, metadata, or image compression is claimed.

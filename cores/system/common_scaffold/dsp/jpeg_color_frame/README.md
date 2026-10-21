# Complete color baseline JPEG encoder

`jpeg_color_frame.sv` joins actual RGB frame storage / MCU formatting,
serial DCT, quantization, baseline symbols, default Huffman coding, entropy
packing, color JFIF headers and EOI into a reusable hardware hierarchy.

Geometry is compile-time: width/height 1..4096, at most 65536 pixels.
Runtime configuration selects 4:4:4 or 4:2:0 and restart interval in MCUs.
The serial, full-frame design is not a continuous real-time video claim.

Load both 64-entry positive quantization tables in natural order, then
handshake `cfg_valid/cfg_ready`. `cfg_done` reports either outcome and
`cfg_error` distinguishes rejection. Rejected configuration preserves the
previous active tables and sampling configuration. Start a frame, then supply
RGB888 raster pixels with SOF on the first pixel and EOL on each row end.
Every transfer requires CE and valid/ready; hold data while stalled.
`m_last` marks the final EOI byte, followed by held `done_valid`.

Error 0x91 is header failure, 0x92 raster framing failure, 0x93 abort,
0x94 illegal control state; entropy failures retain the scan module code.
Discard partial files on error. After acknowledging an error the top locks
until reset. Reset all modules and reload tables before retrying. Successful
frames may run back-to-back with configuration changes and no reset.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/integration/test_jpeg_color_frame.py
```

The test checks twenty actual RTL files with independent integer color/MCU,
DCT/quantization/entropy calculations and parsed headers, plus real Pillow
RGB decoding. It covers five geometries, mode/table switching, rejected
configuration retention, CE and backpressure. JPEG is lossy; random-image
error is recorded without a general quality guarantee. See timestamped
`evidence/jpeg_color_frame_*` reports. No board acceptance is claimed.

Additional checks:

```powershell
python -B cores/system/common_scaffold/dsp/jpeg_color_frame/test_errors.py
python -B cores/system/common_scaffold/dsp/jpeg_color_frame/synth.py
```

Both sampling modes pass malformed SOF/EOL and header/entropy abort cases,
held terminal records, reset-required error recovery, and CE-disabled reset
at configuration, header, capture, DCT, entropy, EOI and DONE boundaries.
Twenty-two recovery files are decoded by Pillow.

Full hierarchy `synth_gowin -noalu -nodsp; check -assert` passes at 16x16
and 33x17: 6935/6953 LUT, 1354/1358 FF, zero DSP, respectively. Each has
192 RAM16SDP4 and one SPX9; frame storage adds one SDPX9B / two DPX9B.
These are synthesis counts, not routed fit or board timing measurements.

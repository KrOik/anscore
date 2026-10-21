# RAW14 payload pack/unpack

Two new fixed-format cores implement4native14-bit pixels <->7payload bytes. Existing raw_pack/raw_unpack support RAW10/12 only; those live modules are unchanged. These are payload stream codecs only: no CSI-2 packet header, word-count, ECC, CRC, D-PHY, pixel Bayer interpolation or colour conversion. Bayer ordering is preserved without interpretation.

The actual Linux V4L2 packed RAW14 specification was fetched and inspected (URL/SHA/excerpt in references.json). For pixelsP0..P3, bytesB0..B3=P0..P3[13:6]. B4={P1[1:0],P0[5:0]}, B5={P2[3:0],P1[5:2]}, B6={P3[5:0],P2[5:4]}. Example pixels0001/0156/2AAB/3FFF produce bytes00/05/AA/FF/81/B5/FE. The independent Python oracle concatenates a24-bit low-bit integer and splits little-endian bytes rather than copying RTL concatenations.

Both modules expose clk/rst_n/ce, s_data/s_valid/s_ready/s_sof/s_eol, m_data/m_valid/m_ready/m_sof/m_eol, protocol_error/error_valid/error_ready/error_code/error_count. PIXEL_BITS is an explicit fixed-format guard:14 is the only legal value; pack input is always14bits, unpack output always14bits. Invalid values report error1 once after reset and never accept data. The initial checked parameter report is generated on physical clock regardless CE; CE qualifies its acknowledgment.

Input transfer is s_valid&&s_ready; ready already includes rst_n&&ce. Output transfers on ce&&m_valid&&m_ready. m_valid and its data/SOF/EOL remain stable while stalled, including CE0. Error transfers on ce&&error_valid&&error_ready. The first pending error code remains stable until acknowledged. Subsequent faults do not stall input or overwrite that pending code; they set protocol_error and increment the32-bit saturating error_count. When an old error is acknowledged on the same edge as a new fault, the new error is immediately retained. protocol_error remains sticky until reset.

Each core has one complete-group register buffer. No output token is exposed until all4pixels/7bytes arrive. Input is paused throughout emission. At ideal CE1, valid source and ready sink, one group takes4input+7output or7input+4output clocks: pack4pixels/11clocks and7bytes/11clocks, unpack4pixels/11clocks. There is no claim of one pixel per clock. This deliberate bounded implementation needs no RAM or unbounded queue.

SOF on the first pixel maps to byte0, and SOF on byte0 maps to pixel0. EOL on pixel3 maps to byte6 and vice versa. Each line must contain a whole number of4pixel/7byte groups. Geometry is not configured; the core validates group-local marker positions rather than an entire frame width/height. Already emitted groups cannot be withdrawn after a later framing fault, and callers should discard a provisional damaged frame according to protocol_error.

At reset, and after an early EOL, input remains unlocked until a new SOF. Accepted non-SOF tokens while unlocked are discarded and each reports error4 (continuation without an initial SOF is not supported). Early EOL at any position before the final group element discards the partial group, unlocks, and reports error2. SOF inside a partial group without early EOL reports error3 and immediately uses that same SOF token as the first element of the new group. SOF between complete groups is accepted as a fresh frame anchor. SOF+EOL together always has early-EOL error2 priority, is discarded, and does not re-anchor; a later separate SOF is required. The complete currently exposed output group remains protected because input cannot transfer during emission.

Synchronous active-low reset overrides CE, discards incomplete groups and exposed output, clears error state/counters, and returns to waiting for SOF. There is no abort pin or fabricated whole-frame atomicity contract.

Run from repository root:

    python -B cores/system/common_scaffold/image/raw14_codec/run_tests.py
    python -B cores/system/common_scaffold/image/raw14_codec/test_protocol.py
    python -B cores/system/common_scaffold/image/raw14_codec/test_roundtrip.py
    python -B cores/system/common_scaffold/image/raw14_codec/test_parameters.py
    python -B cores/system/common_scaffold/image/raw14_codec/test_control.py
    python -B cores/system/common_scaffold/image/raw14_codec/synth.py

AllPASS: standalone pack65536pixels->114688bytes and unpack reverse each exercise every one of16384values in every group position;4random multiline geometries in both directions;8malformed/recovery scenarios cover every earlyEOL/internalSOF index, noSOF and simultaneousSOF/EOL; actual pack->unpack RTL chain65536pixels plus3random frames checks original independent pixel values and markers under random CE/backpressure. Eight invalid static parameters return explicit error1. Two control tests reset partial/held groups, verify healthy standard fixture after reset and CE0stability, and deposit only diagnostic error_count=FFFFFFFE before3natural missing-SOF faults to verify saturationFFFFFFFF. This seeded diagnostic test does not force payload or framing behavior. First-error hold is exercised while multiple new errors arrive and CE0ack is ignored.

Isolated Gowin synthesis(-nodsp; check -assert): raw14_pack160LUT-class, raw14_unpack150LUT-class, each0DSP/0BRAM9. Since the format has one legal fixed14-bit configuration, each top has one genuine synthesis profile, with actual cells/log SHA; duplicate profiles are not fabricated. All simulator/download/fixture/netlist temporaries use automatically removed C: directories. Evidence/logs are small. No combined-fit, routing, board, PHY or electrical validation is claimed.

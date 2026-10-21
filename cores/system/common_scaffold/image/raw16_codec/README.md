# Frame-aware RAW16 byte codec

raw16_pack converts each full16-bit sample into2bytes; raw16_unpack reverses it. The Linux V4L2 Bayer16 reference was actually fetched; references.json records URL/SHA/excerpt and specifies little-endian memory storage. Default BIG_ENDIAN=0 maps1234 to34/12. Optional BIG_ENDIAN=1 maps1234 to12/34 and is a word-order extension, not the Linux default. Bayer pattern is uninterpreted. No CSI2 packet, PHY, demosaic or colour transform is implemented.

Gap check: image/rgb565 already provides RGB888/RGB565 conversion and was not duplicated. stream_bus/rtl/sb_stream_width_adapter.v already provides generic16/8 width conversion. It repeats USER on narrowed bytes and permits partial widened words. This new codec adds frame-marker placement, initial SOF lock, odd-byte EOL rejection and SOF recovery. It does not claim generic width conversion was missing.

Ports: clk/rst_n/ce, s_data/s_valid/s_ready/s_sof/s_eol, m_data/m_valid/m_ready/m_sof/m_eol, protocol_error/error_valid/error_ready/error_code/error_count. Pack data widths16->8; unpack8->16. PIXEL_BITS16 only, BIG_ENDIAN0/1 only. Invalid parameters block input and report error1 once on first physical clock after reset regardless CE. Reset is synchronous active low and overrides CE.

Input transfers on s_valid&&s_ready (ready includes CE and reset). Output transfers on ce&&m_valid&&m_ready; pending output data/markers/valid remain stable while stalled or CE0. Error ACK requires ce&&error_valid&&error_ready. The first pending error code is held until ACK; later faults increment32-bit saturating error_count and set sticky protocol_error without blocking. ACK+newfault retains the new fault. No explicit abort pin.

At reset/unlock, non-SOF tokens are discarded with error4. Pack accepts any sample with initial SOF, including a one-pixel SOF+EOL line. It places SOF on firstbyte and EOL on secondbyte. Unpack requires exactly two bytes per sample: EOL on firstbyte discards incomplete sample, unlocks, reports error2. SOF on secondbyte without EOL reports error3 and reanchors that same token as a new firstbyte. SOF+EOL is always early-EOL error2 and is discarded, even during partial state. Fresh SOF is required after earlyEOL. A valid output already visible cannot be withdrawn by later malformed input. Whole-frame geometry is not configured; only pair-local framing is validated. Caller must discard any damaged frame using error status.

Pack buffers one sample and supports consuming lastbyte and accepting nextsample on same edge: ideal1sample/2clocks. Unpack supports replacing consumed output with nextsample but needs2inputbytes/sample; ideal1sample/2clocks. Neither is1sample/clock. EOL alone does not unlock a valid line; SOF may begin a new frame between complete samples. Synchronous reset clears partial and held outputs plus errors and returns to waiting for SOF.

Commands from repository root:

    python -B cores/system/common_scaffold/image/raw16_codec/run_tests.py
    python -B cores/system/common_scaffold/image/raw16_codec/test_protocol.py
    python -B cores/system/common_scaffold/image/raw16_codec/test_roundtrip.py
    python -B cores/system/common_scaffold/image/raw16_codec/test_parameters.py
    python -B cores/system/common_scaffold/image/raw16_codec/test_control.py
    python -B cores/system/common_scaffold/image/raw16_codec/synth.py

AllPASS:20standalone profiles exhaust65536values in both byte orders and both directions, plus4random line geometries including1/3/17/255widths. Python int.to_bytes/from_bytes is independent of RTL bit slicing. Eight actual RTL pack->unpack chain profiles include full value domain plus1/3/257widths. Twelve malformed/recovery profiles cover oddEOL, midSOF, priority, missingSOF, first-error hold, CE0ACK and healthy recovery. Twelve invalid parameter profiles cover PIXEL_BITS0/15/17/32 and endian-1/2. Four control profiles cover partial unpack and held-output reset, CE0hold, healthy markers, ACK+newfault, and error saturation (diagnostic counter only depositedFFFFFFFE then3natural faults). Root independently tested both directions/endians with explicit1234fixture, exhaustive domain and additional frame sequences.

Four actual isolated Yosys synth_gowin -nodsp/check -assert profiles: pack66LUT-class little endian /69 big endian; unpack61LUT-class in either order. All0DSP/0BRAM9. These are isolated estimates, no combined fit/route/board claim. Temporaries are in automatically cleaned C: directories; retained source/evidence/log files are small. source_freeze.json maps frozen inputs toSHA256; final_validation.json binds source freeze and functional/synthesis evidence hashes. No existing module or shared registry was modified.

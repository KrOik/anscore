# Parallel DVP camera receiver

`dvp_rx.sv` is a real single pixel-clock byte receiver, with a synchronous BRAM FIFO, strict line/frame validation, native gray8 and RGB565-to-RGB888 unpacking. A repository-wide RTL search found no equivalent DVP receiver. Sensor samples cannot be backpressured. No host parsing or full-frame software shortcut is used.

ABI: `clk/rst_n`, `ce`, `start_valid/start_ready`, `abort`; captured `cfg_width/cfg_height[15:0]`, `cfg_mode` (one bit:0 gray8,1 RGB565), `cfg_big_endian`, `cfg_vsync_active_high/cfg_href_active_high`. Sensor input is `sample_valid/vsync/href/data[7:0]`; there is deliberately no input ready. Output is `m_pixel[23:0]/m_valid/m_ready/m_sof/m_eol/m_last`; gray8 occupies low8 with upper zero; RGB565 bytes use selected endian and expand R5/G6/B5 by high-bit repetition to RGB888. `image_width/image_height[15:0]/image_mode` retain captured geometry/mode. `done_valid/done_ready/frame_error/error_code[7:0]` report the transaction.

VSYNC active denotes vertical blank, and HREF active denotes valid line bytes. Only sample_valid1 observes sensor pins, including sync edges. START first waits until a sampled active VSYNC, then a sampled inactive VSYNC with inactive HREF opens capture. Starting mid-frame never silently claims a partial frame. At least one inactive-HREF sample separates lines. Each active-HREF sample contains a data byte, including the rising-HREF sample. Falling HREF closes and validates a line. The next active VSYNC closes and validates the frame. Final HREF falling and VSYNC rising may coincide. HREF active at a frame opening/closing boundary is an explicit sync error. Invalid sample_valid0 cycles may contain arbitrary pin values and do not change sync history.

All sensor sampling and overflow/error detection continue at CE0: CE cannot pause an unbackpressured camera. CE gates START, abort, DONE acknowledgment, FIFO prefetch and output consumption. A valid exposed output token remains stable until CE&&m_ready, including when a sensor error arrives during a host stall. An error immediately latches frame_error/error_code and discards unread FIFO entries; a previously exposed token must drain before DONE. Its markers/data remain unchanged. Abort uses the same drain rule; a subsequent abort cannot replace an already latched error while ERROR_DRAIN is pending. Active-low synchronous reset works at CE0 and cancels all output, including an error pending drain. Idle/DONE ignore abort. Error/abort ignores all new sensor data until DONE is acknowledged and START rearms boundary lock. Success DONE requires validated frame end and complete FIFO/output drain.

All output is provisional until successful DONE. Any error invalidates the entire frame, even an already emitted prefix. Downstream systems must stage/commit accordingly. A lost VSYNC/HREF/sample_valid cannot be distinguished from a long pause, so no automatic timeout is invented; host abort terminates a stuck sensor. The module consumes one armed frame per START, rather than silently overrunning its DONE handshake to capture additional frames.

FIFO_DEPTH legal2..4096, including nonpowers of2. It counts RAM slots; there is one additional output holding register. Full simultaneous read/write accepts a new pixel while consuming the old entry, including wrapped same-address read-before-write behavior. FIFO overflow is explicit when no slot can be freed. Healthy throughput is one gray pixel per clock, or one RGB565 pixel per two byte clocks. Any long-term output deficit eventually overflows finite storage. MAX_WIDTH/MAX_HEIGHT legal1..4096; defaults640/480, FIFO1024. Configured dimensions must be nonzero and within limits.

Error codes:01 invalid static/runtime configuration;02 FIFO overflow;03 long line;04 short line;05 dangling RGB565 half-pixel;06 short frame;07 extra line/long frame;08 invalid sync overlap/internal state;09 host abort. Expected marker positions follow configured raster geometry and may precede later validation errors.

Run from repository root:

```
python -B cores/system/common_scaffold/image/dvp_rx/run_tests.py
python -B cores/system/common_scaffold/image/dvp_rx/test_protocol.py
python -B cores/system/common_scaffold/image/dvp_rx/test_numeric_limits.py
python -B cores/system/common_scaffold/image/dvp_rx/synth.py
```

Main:20 frames/771072 exact pixels. Sixteen small mode/endian/polarity combinations use CE pauses, backpressure, ignored invalid samples, initial mid-frame activity, captured-config mutation and simultaneous final sync edges. Both modes additionally process actual320x240 and640x480 generated camera waveforms with a byte every clock and no output pauses. The pixel oracle is generated independently from source sample values and compared with every RTL pixel and raster marker.

Numeric:14 good frames/139614 pixels, including all65536 RGB565 values in both byte orders,4096-wide/tall edge geometries and FIFO2/3/7/1024/4096;8 invalid configuration profiles. Protocol:26 reports,16 healthy frames (136 pixels). Directed cases hold an exposed token at CE0/m_ready0 while overflow, long/short line, partial pixel, sync overlap and short frame occur, then check hold, drain and recovery. Extra-line error, LOCK/FRAME/DRAIN abort, CE-off resets including ERROR_DRAIN, immutable pending error under abort, and a full nonpower-of-two FIFO sustaining wrapped simultaneous reads/writes are checked. Final full-FIFO frame independently checks every pixel/marker. Reports bind exact RTL SHA256.

Isolated `synth_gowin -nodsp; check -assert`: FIFO1024=564 LUT-class,0 DSP,4 conservative BRAM9; FIFO4096=630/0/12. Count LUT+ALU+MUX+4*RAM16SDP4, and every physical block RAM primitive as2 BRAM9 including SP/SPX9. Both fit15K/4DSP/46BRAM9. No place/route, board, CDC, signal-integrity, sensor setup/hold or external electrical interface claim is made. A real sensor must be sampled on an appropriate pixel-clock edge and configured for matching polarity/byte format.

`references.json` records actual retrieved Espressif OV7670 sensor code and OV7670 datasheet from MIT, URL/SHA256/byte count/excerpts. A failed historical URL is retained honestly. RTL is independently written. All simulation binaries, wave fixtures and downloads use TemporaryDirectory and are automatically cleaned; only small logs and reports remain.

## Synchronous ring repair

Physical coefficient-free pixel FIFO storage now has FIFO_DEPTH+1 slots; logical FIFO capacity remains FIFO_DEPTH, plus one output holding token. Full simultaneous push/read remains accepted at distinct addresses, eliminating device-specific same-address dual-port RAM behavior. Pointer width is clog2(FIFO_DEPTH+1) and wraps at FIFO_DEPTH.

Run `python -B cores/system/common_scaffold/image/dvp_rx/test_ring.py` for depths2/3/7/1024/4096, exact N+holding capacity, full simultaneous acceptance, address/distance invariants, non-power-of-two wrap, CE-off/stall and output marker/order checks. Prior source, logs and evidence are preserved in ../dvp_rx_repair/baseline_before_integration.zip.

Repair verification PASS: main20frames/771072pixels; protocol26reports/16healthy; numerical/parameter regression unchanged PASS; ring5profiles/20632pixels PASS. Isolated Gowin synthesis now depth1024=587 LUT-class/0DSP/6 BRAM9, depth4096=879/0/14 (previous564/0/4 and630/0/12). Added spare physical ring slot costs two conservative BRAM9 blocks per profile. No board claim.

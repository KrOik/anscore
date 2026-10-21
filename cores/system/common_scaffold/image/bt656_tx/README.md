# BT.656 elastic byte transmitter

Original synthesizable RTL implementing SAV, active UYVY bytes, EAV and complete configured blanking. Repository path search found an existing BT.656 receiver and no transmitter. This core fills that missing direction. Input is already UYVY: each two-pixel group is Cb,Y0,Cr,Y1. Byte values are transported verbatim without range clipping or color conversion.

## Scope

This is an elastic ready/valid byte domain formatter, **not a continuous no-backpressure 27 MHz physical transmitter**. Full timing records include 625 rows x 1728 bytes with 720x576 active pixels, and 525 rows x 1716 bytes with 720x480 active pixels. F/V positions are explicitly programmable and are not certified normative 525/625 broadcast line tables. A physical serializer/clock interface, fixed-rate buffering, chroma conversion, ANC/VBI insertion, CRC/EDH and broadcast conformance are outside this module. References include the official ITU recommendation index, a separately developed VHDL camera model and mature Linux UYVY/BT656 format handling; those references do not prove broadcast compliance.

## ABI

`bt656_tx #(MAX_WIDTH=720, MAX_FIELD_LINES=288)` ports:

- `clk,rst_n,ce,start_valid,abort,start_ready`
- `cfg_width,cfg_field_lines,cfg_total_lines,cfg_field1_start,cfg_active0_start,cfg_active1_start` (16 bits each), `cfg_line_bytes` (17 bits)
- `s_data[7:0],s_valid,s_sof,s_eol,s_last,s_field,s_ready`
- `m_data[7:0],m_valid,m_ready,m_sof,m_eol,m_last`
- `done_valid,done_ready,frame_error,error_code[7:0],output_bytes[63:0]`

Every ordinary ready/valid handshake must be CE-qualified. Reset is synchronous, active low, and has priority over CE. Start captures all configuration only when IDLE/start_ready. DONE is held until CE-qualified done_ready, then a new start may be accepted. CE low freezes all state and visible valid output tokens. Config changes while busy have no effect. The producer must hold input under backpressure and the consumer must qualify transfers by CE. m_valid is not a free-running physical clock enable.

Row numbering is zero based. F=0 for rows [0,cfg_field1_start), F=1 afterward. V=0 exactly in [cfg_active0_start,cfg_active0_start+cfg_field_lines) and [cfg_active1_start,cfg_active1_start+cfg_field_lines); V=1 elsewhere. Each row starts with `FF 00 00 XY` SAV (H=0), followed by 2*width active bytes or neutral blank bytes, `FF 00 00 XY` EAV (H=1), and sufficient alternating 80/10 blank bytes to reach cfg_line_bytes. XY is `{1,F,V,H,V^H,F^H,F^V,F^V^H}`. F/V are the current row for both SAV and EAV. No active row requires input while V=1.

Input marker contract: s_sof only on the first active byte of field 0; s_eol only on each active row's final byte; s_last only on the final active byte of field 1; s_field is 0/1 across the corresponding complete active field. Input order is field raster, not progressive woven rows. Each marker is checked on accepted input. Early or missing markers and wrong field report error 2 before forwarding the offending byte. Missing valid input waits indefinitely; no padding or timeout. Active bytes use a registered one-byte buffer and at most one byte every two CE-qualified cycles. Generated SAV/EAV/blanking can emit one byte per cycle.

Output markers describe the **complete timing record**: m_sof only row0/byte0; m_eol on every configured row's final byte; m_last on the final byte of the final row. These differ from active pixel markers. Output data and markers remain stable under backpressure. The complete record must be discarded on any error/reset/abort; already emitted bytes are provisional until successful DONE and cannot be rolled back. output_bytes counts ordinary emitted bytes, including all blanking, and is 64-bit to avoid configuration-product overflow.

Abort is CE-qualified and overrides ordinary handshakes in active states, reports error 3 and cancels all pending traffic. Abort cycle is a cancellation boundary, not an ordinary accepted byte. Abort is ignored in IDLE/DONE. Error 1 reports invalid configuration/static parameters before emitting bytes. Reset clears counters and pending transaction.

## Configuration bounds

MAX_WIDTH 2..32766, MAX_FIELD_LINES 1..32767. Width must be even, >=2 and <=MAX_WIDTH. Field lines 1..MAX_FIELD_LINES. Total rows 2..65535. Field1 start must lie strictly inside the record. Field0 active window must end no later than field1 start; field1 active window must start at or after field1 start and end within total rows. Line bytes is even, >=2*width+8, and <=131070 (largest even 17-bit value). All window arithmetic is widened to 17 bits. These bounds permit no horizontal blank payload (only SAV/EAV) for minimum profiles.

Example profiles used by tests (not normative F/V timing certification):

| Width | Field rows | Total rows | Line bytes | Field1 start | Active0 start | Active1 start |
|---|---|---|---|---|---|---|
|720|288|625|1728|312|22|335|
|720|240|525|1716|262|19|282|

Existing bt656_rx stops successfully after field1's last active EAV and does not require the end-of-record marker there. A wrapper connecting the full transmitter record must consume trailing blanking after RX completion instead of continuing to feed the stopped receiver.

## Reproduce

```
python -B cores/system/common_scaffold/image/bt656_tx/run_tests.py
python -B cores/system/common_scaffold/image/bt656_tx/test_protocol.py
python -B cores/system/common_scaffold/image/bt656_tx/test_numeric.py
python -B cores/system/common_scaffold/image/bt656_tx/synth.py
```

Main: four complete records, including 1080000-byte and 900900-byte SD-sized records, every byte and all output markers independently checked. The Python oracle directly constructs complete SAV/EAV/parity/blanking records and deterministic active payload; it imports no receiver helpers. Tests inject CE gaps/backpressure and mutate captured configuration. Protocol: 46 held reports, abort and CE-off reset in all three active FSM states, 12 invalid configurations, all four markers plus missing final last, starvation, terminal cancellation/reset and healthy recovery. Numeric: exact maximum width32766, field-lines32767/total-lines65535 and line-bytes131070 independently exercised; four invalid static parameter profiles rejected. The maximum row/column bounds are independently tested, not an 8GB maximum-product record simulation.

Isolated `synth_gowin -nodsp; check -assert` passes: explicit default profile 914 LUT-class, maximum static profile 877 LUT-class, both 0 DSP/0 BRAM9. LUT-class counts LUT/ALU/MUX plus four times RAM16SDP4; all block RAM primitives count as two BRAM9. No P&R, board or physical timing claim. Logs and JSON bind exact RTL SHA. Source freeze covers code/docs/references; FINAL_VALIDATION binds reports. Generated simulators/vectors use TemporaryDirectory and are removed. Network source responses are kept only as hashes/excerpts; baseline logs are retained.

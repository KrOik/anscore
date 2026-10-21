# BT.656 byte receiver

Implemented byte-clock-domain BT.656 session receiver. No pin PHY, PLL, clock-domain crossing, ADC setup, line reorder or deinterlacing is included. Output is the original Cb Y0 Cr Y1 (UYVY) byte sequence. One session extracts two fields in **field raster order**: all F=0 active lines followed by all F=1 active lines. This is not spatially interleaved progressive scan. F0 is the required first active field: this core does not automatically lock an arbitrary starting active-field phase or validate exact broadcast-standard V/F line-number transition positions. Configure width=720 and field_lines=288 for 576-line PAL output or 240 for 480-line NTSC output.

## ABI

`bt656_rx #(MAX_WIDTH=720, MAX_FIELD_LINES=288)` has clk/rst_n/ce, start_valid/start_ready, cfg_width[15:0], cfg_field_lines[15:0], abort; s_data[7:0]/s_valid/s_ready/s_last; m_data[7:0]/m_valid/m_ready/m_sof/m_eol/m_last/m_field/m_field_sof; done_valid/done_ready/frame_error/error_code[7:0]. Configuration is captured at CE-qualified start and later input changes do not affect a session. Width must be even, 2..MAX_WIDTH; field_lines 1..MAX_FIELD_LINES. Static maxima must be within width 2..32766, lines 1..32767. Reset is synchronous active low and takes effect with CE=0; every other transfer, abort and state transition requires CE=1. Consumers count handshakes only with CE=1. A stalled output token remains stable until acceptance, abort or reset.

m_sof marks only the first F0 active byte. m_field_sof marks each field's first active byte. m_field is F on every valid byte. m_eol marks byte 2*width-1 of each active line; m_last marks only the final byte of the final F1 active line. One output register permits a byte per enabled cycle. There is no frame RAM and no latency guarantee when either side stalls.

## Parsing and completion

SCAN recognizes FF 00 00 XY in blanking, allowing FF FF prefix overlap, and discards other blanking bytes. XY must have bit7=1 and P3=V xor H, P2=F xor H, P1=F xor V, P0=F xor V xor H. Strict detection rejects every single-bit XY corruption; **there is no correction**. Valid V=1 SAV/EAV and V=0 EAV in SCAN are ignored. V=0 SAV starts a fixed 2*width-byte active line, and F must match the expected field. Payload is never searched for TRS, so FF 00 00 XY-like active bytes pass through unchanged. Immediately after those bytes an exact FF 00 00 XY EAV with matching F, V=0, H=1 is mandatory. Short/long active payload produces an EAV mismatch; output already emitted must be discarded.

After field_lines validated active lines, expected F advances 0 to 1; after the second field's final valid EAV the session completes. DONE cannot precede acceptance of the final output byte. s_last is optional on that final EAV's XY and is an error at every earlier byte. No bytes after the final EAV are consumed in this session. This is finite-session framing; a continuous hardware stream requires software/session restart or a separate continuous wrapper. Stopped sources without s_last cannot be distinguished from a valid arbitrarily long pause; the caller supplies a timeout/abort policy.

**All output is provisional until successful DONE.** Every error invalidates the entire session, including already accepted pixels. DONE and error_code remain held until CE-qualified done_ready, then a new session can start. start_ready is low while running or DONE is held. Abort while idle is ignored. Inputs may be backpressured; a real free-running BT.656 camera cannot be stalled and needs an external sufficiently sized FIFO/CDC and explicit overflow handling. This core alone is not a lossless physical camera interface under arbitrary downstream stalls.

Error codes: 1 invalid configuration; 2 bad XY protection; 3 active field order/count mismatch; 4 premature s_last/truncation; 5 missing/malformed/mismatched EAV (including active length); 6 internal illegal state; 7 explicit abort. Abort may discard a pending unaccepted output token. No unreported correction, CRC or pixel-range check is claimed.

## Evidence and commands

From repository root:

```
python -B cores/system/common_scaffold/image/bt656_rx/run_tests.py
python -B cores/system/common_scaffold/image/bt656_rx/test_protocol.py
python -B cores/system/common_scaffold/image/bt656_rx/synth.py
```

Main suite: 34 tests, including actual 720x576 and 720x480 output-byte comparisons, full 625/525 field-line records, 1728/1716-byte line timing before the final EAV termination, all eight F/V/H combinations, all eight single-bit XY corruptions, short/long active lines, field counts/order, invalid runtime/static parameters, arbitrary active FF0000 prefix, CE stalls, output backpressure, markers and DONE hold. Geometry cases also include 2x2, 4x6 and 16x24. The standard-size fixture uses synthetic front-loaded vertical blanking rather than exact normative V/F transition line numbers; all active and blanking line-byte counts are exercised. Payload 00/FF values test transport robustness and do not assert legal broadcast-range pixels. Each received byte is checked against a Python-generated oracle; the pixel source pattern is independent of RTL.

Protocol suite: 16 abort positions over SCAN/SAV/payload/EAV, CE-disabled abort non-effect, reset with CE disabled, configuration snapshot, parity/field/EAV/truncation errors and 21 healthy recovery sessions. Resource synthesis uses synth_gowin -nodsp and check -assert: default 385 LUT-class, 0 DSP, 0 BRAM9; small 16x12 profile 398 LUT-class. LUT-class counts LUT+ALU+MUX+4*RAM16SDP4; each DP/SP-class RAM would count as two BRAM9. No PNR timing or board validation claimed.

references.json contains SHA256 and actual excerpts downloaded from the pinned open-source BT656 camera model (independent SAV/EAV parity expressions) and Linux v6.12 adv7180 (BT656 bus / UYVY / 720x480-or-576). fetch_references.py re-downloads in memory. These are reference checks, not copied implementation code or a claim of full standard certification. Simulation and synthesis binaries use TemporaryDirectory and are removed; small logs are retained.

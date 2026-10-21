# Framed YUV422 byte layouts

Two independent synthesizable adapters convert canonical 32-bit macro-pixels `{Y0,Y1,Cb,Cr}` to/from an 8-bit packed byte stream. They do not perform chroma subsampling, reconstruction, color conversion, chroma siting, or range conversion. Existing `chroma_422.sv` performs real 444→422 FIR resampling and emits fixed `{Y0,Cb,Y1,Cr}`; it does not replace these framed runtime layout adapters. Rearrange its fields explicitly when connecting the canonical interface.

| cfg_order | Byte order |
|---|---|
|0 YUYV|Y0 Cb Y1 Cr|
|1 UYVY|Cb Y0 Cr Y1|
|2 YVYU|Y0 Cr Y1 Cb|
|3 VYUY|Cr Y0 Cb Y1|

ABI: `clk,rst_n,ce,start_valid/start_ready,cfg_order[1:0],abort`; `s_data`/`m_data` width 32/8 for packer and 8/32 for unpacker; both streams have `valid,ready,sof,eol,last`. `done_valid/done_ready,done_error,error_code[7:0],busy`. Start captures order; changing configuration during the frame has no effect. Active-low synchronous reset works even with CE=0. Every handshake requires CE=1. Output and DONE remain stable while stalled or CE=0. Start is accepted only idle without pending DONE; one transaction must finish/acknowledge before the next. No implicit frame start. Ready may remain high when CE=0 but no transfer happens.

Parameters WIDTH even 2..65534, HEIGHT 1..65535. Each macro-pixel covers two horizontally adjacent pixels; every row contains WIDTH/2 macro-pixels and 2*WIDTH bytes. SOF is exactly first macro/byte; EOL exactly last macro/byte of each row; LAST exactly final macro/byte. Both adapters verify every input marker against frame geometry. Output markers are regenerated. Invalid static dimensions terminate a start with error1, abort while active error2, any marker mismatch error3. Errors terminate transaction and discard buffered data; already emitted data is provisional and the whole failed frame must be discarded. DONE success occurs only when the final output beat is accepted. Abort has priority over transfers; reset overrides CE; idle abort is ignored. Unpacker stores four byte phases in one word then stalls input while its macro output waits; packer holds one macro and emits four bytes. There is no frame RAM, timeout, padding insertion, or bandwidth claim of one macro per clock. Geometry must match the application; extra beats after a completed frame see no ready and require a new start.

Verification commands (repository root):
```
python -B cores/system/common_scaffold/image/yuv422_bytes/run_tests.py
python -B cores/system/common_scaffold/image/yuv422_bytes/test_packer.py
python -B cores/system/common_scaffold/image/yuv422_bytes/test_unpacker.py
python -B cores/system/common_scaffold/image/yuv422_bytes/test_protocol.py
python -B cores/system/common_scaffold/image/yuv422_bytes/test_parameters.py
python -B cores/system/common_scaffold/image/yuv422_bytes/synth.py
```
Main suite has 32 cases and 64 real frames, covering 2×1,16×12,720×4,1920×2 in all four orders and both directions. Python constructs independent canonical words and explicit byte permutations; lanes independently sweep all 256 values on large profiles. It compares actual RTL data and every marker, CE and ready stalls, output hold, captured mode and repeated frames. Protocol suite aborts each input byte phase and pending output, flips each marker at every input position, resets every phase with CE=0, checks DONE hold and a healthy frame after failures. Twelve invalid static profiles are rejected. No claim of hardware or routed timing validation.

`synthesis.json` is source-bound isolated `synth_gowin -nodsp; check -assert` evidence: default16×12 pack262 / unpack348 LUT-class;1920×1080 pack879 / unpack975. All profiles0DSP,0BRAM. LUT-class includes LUT+ALU+MUX+4×RAM16SDP4; every SP/SPX9/DPB/DPX9B/SDPB/SDPX9B counts2BRAM9. Conservative budget15K/4DSP/46BRAM9. Constant modulo geometry can cost logic for non-power-of-two widths. Timing/board tests remain pending. Simulation binaries and generated test data use TemporaryDirectory and are removed; source/evidence/logs remain.

External reference: Linux V4L2 packed YUV specification pinned to v6.12, actually fetched with curl; URL, SHA256 and table excerpt in references.json. This specification informed the byte layout; RTL is original.

Narrow registry entries test_packer.py/test_unpacker.py each execute16 cases32frames and write distinct evidence_packer.json/evidence_unpacker.json. run_tests.py defaults to all32cases; --kind pack/unpack selects a direction. Original freeze is retained as freeze_hashes_initial.json; RTL is unchanged.

# NV12 / NV21 frame-memory layout engine

`img_nv12_layout.v` maps the existing 8-bit YUV420 macro stream into NV12/NV21
frame planes or reads those planes back into the same macro stream. It provides
byte memory transactions; no DDR controller, cache, AXI adapter or YUV444 sampling
filter is included. A source already sampled to 4:2:0 is required.

The existing `production_accel_25k/rtl/acc_yuv420_pack.v` was inspected first. It
performs local lane/tile packing and vertical averaging with fixed small counters,
and has no frame plane addresses, configurable stride or memory readback. This
module therefore implements the missing frame layout rather than replacing that
kernel. The stream contract matches `chroma_420_to_444` and is tested with that
actual reconstruction module.

## Geometry and macro stream

Compile-time `WIDTH,HEIGHT` are in 1..65535, with `CW=ceil(WIDTH/2)` and
`CH=ceil(HEIGHT/2)`. Data is 17 bits: tag bit16, then two bytes high-to-low.

Walk each image row in horizontal pairs. Emit/consume tag0 `{0,Y0,Y1}` at each
pair. On odd-numbered rows, and on the final row if height is odd, follow every
Y pair with tag1 `{1,U,V}` at the same horizontal pair. A UV macro belongs to
chroma row `floor(y/2)`. `s_sof/m_sof` marks only the first Y macro of the frame;
EOL marks the last macro of the row (UV on chroma-bearing rows, otherwise Y).

Odd widths are explicitly supported: the last Y pair's low-byte dummy is ignored
on write and produced as zero on read. Its U/V pair remains present in full.
Odd heights have an additional chroma row carried on the last image row. The
engine does not compute chroma averages or duplicate source rows. No chroma phase
conversion is performed. This is the same ceil-geometry convention as the existing
reconstruction module, and downstream consumers must agree on that convention.

## Atomic configuration and frame command

`cfg_valid/cfg_ready` commits `cfg_nv21`, 32-bit absolute `cfg_y_base`,
`cfg_uv_base`, byte strides `cfg_y_stride/cfg_uv_stride`, and inclusive allowed
memory bounds `cfg_address_min/cfg_address_max`. Configuration is accepted only
when idle and takes priority over start. `cfg_done` and `cfg_error` are one-enabled-
cycle result pulses. Invalid config preserves all previous values.

Requirements checked before commit:

- Y stride >= WIDTH, UV stride >= 2*CW; arbitrary larger byte strides are allowed.
- Both plane bases and final active bytes lie within the inclusive address bounds.
- Exact 64-bit end-address calculations do not wrap through the 32-bit address space.
- The two bounding plane spans do not overlap. This conservatively includes row
  padding within each span, so interleaving one plane inside another's padding
  is rejected even if active-byte addresses would be disjoint.

The active last addresses are `Ybase+(HEIGHT-1)*Ystride+WIDTH-1` and
`UVbase+(CH-1)*UVstride+2*CW-1`. Neither row padding nor inter-plane gaps are touched.
NV12 writes U then V; NV21 writes V then U, while macro streams always use U,V.

`start_valid/start_ready` starts one frame, with `start_read=0` for stream-to-memory
or `1` for memory-to-stream. Mode and config remain fixed until completion. A frame
must be explicitly started; no input is accepted while idle. New config/start is
blocked until `done_valid/done_ready` is consumed.

## Memory, CE and backpressure

Memory request: `mem_req_valid/mem_req_ready`, `mem_req_write`,
`mem_req_addr[31:0]` (byte address), `mem_req_wdata[7:0]`.
Memory response: `mem_rsp_valid/mem_rsp_ready`, `mem_rsp_rdata[7:0]`,
`mem_rsp_error`. Exactly one request is outstanding. Every read **and every write**
requires one ordered response. A successful write response means the byte write
is complete or irrevocably committed. There are no byte strobes because every
transaction is exactly one byte. Unsolicited/duplicate responses are not supported.

All interfaces use the repository's **CE-qualified** transfer convention:
`clk_en && valid && ready` on a rising edge. This also applies to the memory bridge.
Request valid remains asserted with stable address/data during CE pauses or
backpressure; an external bus that can transfer independently of CE needs a
proper buffering adapter, not a direct wire connection. Response/source payloads
must be held stable until their CE-qualified transfer. Stream outputs remain
stable while blocked. Ready outputs go low with disabled CE or reset. Completion
status stays stable until accepted. One-byte requests serialize the frame and are
intended as a clear layout/addressing engine, not a high-throughput DDR burst DMA.

Reset is asynchronous active-low and aborts pending work. The external bridge must
also flush any outstanding response, or use transaction epochs to prevent an old
response from being applied to a new frame. Partial prior writes are not rolled
back. There is no response timeout; a hung memory bridge requires system recovery.

## Errors

`done_valid` indicates completion; `done_error` and `error_code[2:0]` remain stable
until `done_ready` accepts the result. Zero code means successful frame completion.

| Code | Meaning | Effect |
| --- | --- | --- |
| 1 | Input macro tag/SOF/EOL differs from expected geometry | Abort before issuing any write for that macro |
| 2 | Memory response reports error | Stop issuing requests and abort frame |
| 3 | Defensive runtime address check fails | No invalid request is exposed; abort frame |

Error handling cannot undo writes or revoke already emitted read macros. Downstream
frame consumers must discard an incomplete frame after an error. Memory errors may
have device-specific partial side effects even when a response reports failure.
Reset clears configuration, completion and the current frame. No cryptographic
or fault-tolerance claims are made.

## Tests and synthesis

From repository root:

```powershell
python -B cores/system/common_scaffold/image/nv12_layout/run_tests.py
```

The independent Python reference creates Y/U/V planes, expected absolute addresses,
NV12/NV21 bytes, preserved padding and macro values. An SV memory bridge injects
random request stalls/response delays, while CE and consumers pause independently.
Every transaction is compared to the address/data golden and the whole 8192-byte
memory is checked, including untouched gaps. Readback also drives the real existing
`chroma_420_to_444` module; its output is checked against a separate nearest-sample
Python reference with that module's documented tie-to-greater-coordinate rule.

Five geometries (1x1,2x2,3x5,8x6,9x4), tightly packed and padded strides, reverse
plane order, exact inclusive memory bounds and both NV formats PASS: 656 successful
memory requests and 208 reconstructed YUV444 pixels. Also checked: malformed macro,
memory response error, invalid stride/overlapping planes/out-of-range and wrapping
config rejection with old config retained, request/output/completion stability,
and reset while a transaction is outstanding. Code3 is a defensive unreachable
check under accepted configuration, not a tested fault-injection claim.
`test_result.json` records source/dependency hashes. Temporary vectors and simulator
binaries are automatically deleted. No physical DDR/camera/JTAG test was run.

With OSS CAD Suite bin/lib on PATH:

```powershell
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/nv12_layout/img_nv12_layout.v; synth_gowin -top img_nv12_layout -noalu -nolutram; stat"
```

Default 8x6 isolated synthesis: 1380 LUT1..4, 265 MUX2_LUT5 + 1 MUX2_LUT6,
379 FF, 0 DSP/BRAM, CHECK 0 problems (`synthesis.log`). These are generic mapped
counts only; there is no placement/routing or clock/setup/hold signoff. Parameter
changes require renewed synthesis. Parent task owns shared source/runner integration.

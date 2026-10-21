# Stream / bus IP

Eight isolated RTL modules implement streams, register access, AXI-Lite routing and bounded AXI4 memory access. The two historical `_placeholder` module names remain for source compatibility; their implementations now perform real routing/storage. Existing board tops and UART contracts are unchanged. Local simulation does not establish synthesis, timing or board qualification.

| Module | Implemented scope |
|---|---|
| `sb_stream_elastic` | One elastic entry retaining data/KEEP/USER/LAST. Combinational backward READY. |
| `sb_stream_register_slice` | `STAGES>=1` elastic entries. Registers forward payload; READY remains combinational through stages. |
| `sb_stream_width_adapter` | Byte widths with integer ratio, low lanes first, lane-preserving KEEP. Widening flushes at LAST/full word and zero-pads. Narrowing emits all chunks, including zero-KEEP chunks. |
| `sb_stream_rr_arbiter` | Frame-locked round robin through owner gaps until accepted LAST; one elastic output. No timeout/preemption for missing LAST. |
| `sb_axil_register_bank` | Aligned 32/64-bit RW registers with byte strobes, independent AW/W capture, one outstanding read and write. Invalid address SLVERR; simultaneous same-register read/write reads previous value. |
| `sb_axil_crossbar_placeholder` | One initiator to `PORTS` slaves, independent read/write and AW/W, uniform windows selected by `address >> REGION_ADDR_BITS`. Local slave addresses have region bits removed. Unmapped region DECERR. Slave response codes pass through. |
| `sb_axi4_native_bridge` | AXI4 to one native byte-addressed request/response port. Aligned full-width FIXED (1–16 beats) / INCR (1–256), byte strobes, ID retention, independent read/write admission, fair alternating backend arbitration. |
| `sb_axi4_burst_bridge_placeholder` | Native bridge plus synchronous RAM, default 1024 words. `MEM_WORDS` is configurable. No external memory pins; use `sb_axi4_native_bridge` for another backend. |

## Transfer contracts

All resets are asynchronous active-low `rst_n` and abort buffered transactions. The AXI RAM is not erased on reset; startup contents are unspecified. System-level reset coordination is required.

Native **stream** transfers occur on `clk_en && valid && ready` at the rising edge. Connected endpoints must share this enable convention. Payload and VALID remain stable while waiting; CE=0 deasserts input READY and retains pending output. Direct connection to an always-running AXI Stream receiver requires an enable adapter. Widening retains the first USER; a differing later USER pulses `error` for one physical clock while preserving the data transfer. This pulse needs an always-clocked observer.

AXI and native **memory** interfaces use ordinary `valid && ready` every rising edge. CE gates only new requests: AW/W/AR for the AXI-Lite bank/crossbar, and AW/AR for the AXI4 bridge. AXI4 WREADY becomes available after AW acceptance and continues while CE=0. Buffered downstream requests, B/R responses, and native memory transactions continue on ordinary clock edges. Every stalled VALID payload remains stable. AXI4 W-before-AW is legally stalled until its AW arrives; AW and AR may be outstanding concurrently.

The crossbar covers `[port * 2^REGION_ADDR_BITS, (port+1) * 2^REGION_ADDR_BITS)`. Each slave sees only the low `REGION_ADDR_BITS` address bits. More than one slave can exist when PORTS is not a power of two; unused windows return DECERR without issuing slave traffic. It is a single-initiator crossbar, with no multi-initiator arbitration or arbitrary per-slave maps.

## AXI4 memory behavior

The bridge accepts only aligned full-data-width accesses. DATA_WIDTH must contain a power-of-two number of bytes (1–128); address width is 1–32 bits. WRAP/reserved burst types, narrow/oversized transfers, misalignment, FIXED length above 16, address overflow and any burst crossing 4 KiB return SLVERR without a native access. Rejected writes drain exactly AWLEN+1 W beats; rejected reads emit exactly ARLEN+1 zero-data SLVERR beats with final RLAST. Unsupported protocol features are not silently approximated.

WLAST must agree with AWLEN on every accepted W beat. A mismatch pulses `protocol_error` and makes B=SLVERR. AWLEN still controls completion, so early WLAST does not truncate a burst, and missing final WLAST does not cause an unbounded extra drain. Accepted write data may already have reached memory; there is no rollback. A master that stops before supplying its announced beat count cannot receive B. Native memory errors accumulate into B or become the corresponding R beat's SLVERR/zero data. Later beats still finish. The RAM wrapper reports out-of-range words as errors; a burst partially inside its memory can have earlier legal writes committed.

The native port exposes `mem_req_valid/ready`, `mem_req_write`, byte address, full-width data and byte strobes. Each accepted request needs exactly one `mem_rsp_valid/ready` response carrying read data and error (also for writes). One native request is outstanding; the entire request is registered before VALID and held under backpressure. A backend may delay or stall responses, which must remain valid until accepted. No timeout, native cancellation, AXI lock/cache/protection/QOS fields, multiple outstanding IDs, reordering or interleaving is implemented. Arbitration alternates read/write when both need service; throughput is intentionally conservative.

## Group regression

Run from the repository root:

```powershell
python cores/system/common_scaffold/stream_bus/run_tests.py
```

The standard-library runner adds bundled OSS CAD Suite `bin` and `lib` to PATH, compiles with `iverilog -g2012`, and runs eight cases. It creates a new timestamped evidence directory with commands, exit codes, logs and RTL/TB hashes; existing output directories are rejected. `--iverilog`, `--vvp` and `--output-dir` override defaults.

The group covers the original stream/width/arbiter/register tests; real three-slave routing with independent downstream AW/W/AR stalls, address stripping, byte writes, decode errors, concurrent read/write, CE and reset; and real AXI4 RAM/native-backend readback with 1/4/16/32/256-beat traffic, FIXED/INCR, IDs, byte strobes, backend request stalls/delayed responses, R/B stalls, concurrent directions, CE, WLAST errors, rejected formats, 4 KiB rejection, range errors and reset. The eighth case checks that an invalid width conversion fails with the intended parameter diagnostic. This is bounded group coverage, not exhaustive AXI protocol verification.

`sim/tb_sb_axi4_placeholder.sv` and the old placeholder branch in `sim/tb_sb_axil.sv` are retained as historical rejection-endpoint tests; they are no longer active runner cases because the old rejection behavior was intentionally replaced. Earlier evidence remains intact. Synthesis and board programming have not run; no device resource impact is claimed.

# Common memory IP scaffold

Portable memory RTL and functional native DMA engines. No board-top, crypto
project, shared build script, or UART contract is changed. The three historical
`*_stub` module names remain for source compatibility; they now perform transfers.

| Module | Status | Default configuration |
|---|---|---|
| `cip_sync_sp_ram` | Functional minimal | 256 x 32, byte writes, synchronous read |
| `cip_sync_tdp_ram` | Functional minimal | Same-clock 256 x 32, two request/response ports |
| `cip_sync_fifo` | Functional minimal | 16 x 32, registered output, synchronous RAM read |
| `cip_dma_descriptor_chain_stub` | Functional compatibility wrapper | Decoded descriptor chain, actual memory-to-memory copies |
| `cip_dma_stream_to_memory_stub` | Functional compatibility wrapper | Stream-to-memory writes, partial final beat |
| `cip_dma_memory_to_stream_stub` | Functional compatibility wrapper | Memory-to-stream reads, partial final beat |
| `cip_dma_stream_native` | Functional native core | Direction parameter, explicit abort input |
| `cip_dma_descriptor_chain` | Functional native core | Explicit abort, descriptor count/tag and chain bound |

## Shared timing contract

All modules use `clk`, asynchronous active-low `rst_n`, and shared `clk_en`.
A transfer occurs on a rising clock edge **only when `clk_en && valid && ready`**.
Both endpoints must use the same enable; these are not unqualified AXI channels.
`clk_en=0` freezes all state, including pending valid and response payload.
Payload is held while a response is stalled. Reset cancels pending responses and
flushes FIFO occupancy; reset does not initialize or clear RAM contents.

RAM addresses are **word indices**, not byte addresses. `DATA_WIDTH` is a positive
multiple of 8. `ADDR_WIDTH` is 1..30, and `DEPTH` is 1..2**ADDR_WIDTH.
Byte lane zero is bits 7:0; each asserted `req_wstrb` bit writes that byte.
Each RAM port has a one-entry response slot. A consumed response may be replaced
by a new accepted request at the same enabled edge. An unwritten word is undefined.

- SP: `rsp_error=1` for out-of-range addresses, with zero response data and no
  memory access. Successful reads return the word; successful writes return the
  **previous word** (read-first), which can be undefined before initialization.
- TDP: `*_rsp_error=0` success, 1 out of range, 2 collision (B only).
  Simultaneous same-address requests involving a write accept A and return error
  2 on B without a B memory access. Same-address dual reads are allowed. Reads
  return memory data; writes and errors return zero. Zero-strobe write commands
  still participate in collision arbitration. Arbitration and read enables
  exclude every visible read/write collision, allowing `no_rw_check` BRAM mapping.
- FIFO: `level` includes the output slot, so total capacity is exactly `DEPTH`.
  `DEPTH=1` and non-power-of-two depths work. An input can replace an output at
  full occupancy if that output is consumed at the same enabled edge. There is
  no combinational input-to-output data bypass. `out_data` is meaningful only
  when `out_valid=1`. FIFO width can be any positive number of bits.

## Native DMA contract

The DMA addresses and lengths use **bytes**; the standalone RAM modules above use
word indices. A byte-to-word address adapter is required if they are connected.
The memory endpoint is a native valid/ready request followed by one valid/ready
response. Both reads and writes require a response; an error response means the
beat failed. At most one memory request is outstanding, with no bursts, CDC,
AXI framing, address translation, or assumed zero-cycle response. Responses may
arrive after arbitrary latency and must be held until accepted.

All endpoints share `clk_en`. Request, stream and completion payload remains
stable while stalled and all internal state freezes when `clk_en=0`. `cmd_ready`
is high only when idle; one completion follows each accepted command and remains
until consumed. `busy` includes the pending completion. `done=irq` denotes its
**accepted transfer**, not a sticky interrupt. Completion echoes the command tag;
chain completion also echoes the head address and asserts `rsp_terminal`.

### Stream engines

`cip_dma_stream_native.DIRECTION=0` writes the input stream; value 1 reads memory
and produces an output stream. The original two wrapper names fix that parameter
and tie abort low, preserving every original port. `DATA_WIDTH` is a positive
multiple of 8; other width parameters are positive. Each nonempty command address
must be aligned to `DATA_WIDTH/8`, and its byte range must fit `ADDR_WIDTH`.
An arbitrary positive byte length is supported through low-lane strobes/keep on
the last beat. A zero-length command succeeds without stream or memory activity,
including at an unaligned address.

The input must have **exactly** the expected low-contiguous `s_keep` and `s_last`
on the final beat; holes, a short keep, early last and missing last terminate with
status 3 before writing the malformed beat. Previously acknowledged writes remain
committed. After this response the producer must drop the remaining failed packet;
the engine does not silently drain or consume the next command's stream. Read
output masks unused final byte lanes to zero. Writes count bytes after successful
memory acknowledgements; reads count bytes after the output consumer accepts them.
The completion reports this committed prefix even on an error or abort.

### Descriptor engine

`cip_dma_descriptor_chain` requests a descriptor by its byte address from the
**external decoded-descriptor endpoint**. There is no assumed packed descriptor
layout or hidden software stub. A descriptor supplies source/destination addresses,
byte length, next address, last bit, tag and error; the RTL then performs actual
read/response/write/response transactions for every beat and follows `next` until
`last`. Next/head addresses are opaque to this endpoint; address zero is valid.
Each descriptor's nonempty source/destination must meet the stream engine's
alignment/range rules. Nonidentical overlapping source/destination ranges are
rejected (status 9), while copying a range to itself is legal. Successful prior
writes are never rolled back after a later descriptor failure.

`MAX_DESCRIPTORS=256` bounds the number fetched per command. A nonterminal cycle
reaches this bound and returns status 8, rather than looping indefinitely. The
cumulative byte count must fit `LEN_WIDTH`; an overflowing descriptor is rejected
before any of its data transfers. Zero-length descriptors complete and count
normally. The native core reports `rsp_descriptors` (fully copied descriptors) and
`rsp_descriptor_tag` (last fetched descriptor tag, also for a descriptor error).
The compatibility wrapper retains the old port list and does not expose these
two extra fields; it accepts the new optional `MAX_DESCRIPTORS` parameter.

### Errors, abort and reset

| `rsp_status` | Meaning |
|---|---|
| 0 | Successful completion, including zero length |
| 2 | Invalid alignment, overflowing address range or cumulative chain byte count |
| 3 | Input stream keep/last mismatch |
| 4 | Memory response error |
| 5 | Aborted command (native cores) |
| 7 | Descriptor response error |
| 8 | Descriptor-count limit reached without `last` |
| 9 | Unsupported overlapping source/destination ranges |

`rsp_error` is `rsp_status != 0` when `rsp_valid`. Native-core `abort` is sampled
on enabled edges, latched through execution, and never withdraws an already
visible memory/descriptor request or stream output. Such a transaction drains
before the abort completion; a successful write/output still counts. A memory or
descriptor error on the draining transaction takes precedence. An asserted abort
on command acceptance rejects that command with status 5 and no bus activity.
The compatibility wrappers have no abort input; use the native cores if required.

There is no autonomous timeout. A memory/descriptor responder that never responds,
or a consumer that never accepts a previously visible output, can stall abort.
This preserves transaction integrity; recovery from a permanently dead endpoint
requires a coordinated domain reset. Reset cancels local work and responses;
reset the responder too or drain its orphan response externally before reuse.
Memory already written remains written; reset is not rollback. No command queue
or multi-ID/out-of-order response handling is implemented.

## Verification

From the repository root:

```powershell
python cores/system/common_scaffold/memory/run_tests.py --dma-only
python cores/system/common_scaffold/memory/run_tests.py
```

The runner finds the local OSS CAD Suite and saves commands/logs/source/test
hashes to a new `build/run_*` directory. `tb_cip_dma_e2e.v` is the active DMA group
regression. It performs actual byte-oracle stream writes and reads at 32/64-bit
widths, partial tails, request/stream/completion backpressure, enable pauses,
zero-length and malformed commands, stream keep/last failures, memory errors,
abort drainage, buffered reset, two-descriptor copying, chain cycles and descriptor
errors. The old `sim/tb_cip_dma_stubs.v` is retained as a **legacy unsupported-
contract test**, excluded from the active runner; see `sim/LEGACY_DMA_TEST.md`.

The RAM/FIFO sources and their existing tests are unchanged. Historical evidence
in `build/run_20261015_141044_254503` applies to their baselines and to the retired
unsupported DMA scaffold only. Earlier 5-LUT stub figures do **not** describe the
new DMA engines. The new DMA has group simulation evidence; its resource impact
is **unknown**, with no new synthesis, placement/routing or board verification.

The optional `--synth` runner path remains available for later isolated synthesis;
source dependencies are included, and it was not run in this development task.
The repository SOP records inferred-BRAM hardware issues; these portable RAM
modules still require a board-qualified primitive adapter and hardware tests.

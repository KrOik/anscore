# Ordered completion buffer

`ordered_completion_buffer` allocates tags to submitted work, accepts result
completions in arbitrary tag order, and retires results in original submission
order. Request metadata travels with each result. This is a small single-clock
transaction primitive for connecting several variable-latency workers to an
ordered consumer; it is not an AXI master, DMA engine, CDC bridge, or instruction
retirement unit.

## Interface contract

All activity uses the rising edge of `clk`. `rst` is synchronous active high and
has priority over all transfers. `a_ready`, `c_ready`, and `m_valid` are gated low
while reset is asserted. The reset edge clears ownership, count, pending output
and diagnostics; payload RAM and invalid output fields are not reset. Reset
cancels every outstanding transaction. Workers must be reset or their orphaned
results must be discarded before the buffer is reused.

There is **no clock enable**. Transfers occur on every `valid && ready` edge.
Connect a CE-qualified ANSCORE interface through a semantics adapter rather than
directly treating its VALID as standard ready/valid.

| Port group | Transfer and meaning |
| --- | --- |
| Allocation | `a_valid && a_ready` accepts one `a_meta` and allocates the slot index shown on `a_tag` on that edge. The scheduler samples that tag and passes it to the worker. |
| Completion | `c_valid && c_ready` consumes one `c_tag`, `c_data`, `c_error`. `c_ready` is always high outside reset. An allocated, not-yet-completed tag stores the result; other completions are ignored and diagnosed. |
| Retirement | `m_valid && m_ready` retires the oldest submitted transaction, publishing `m_meta`, `m_data`, `m_error`, then releases its slot. A younger completed transaction cannot pass an unfinished older one. |
| Occupancy | `occupancy` counts all allocated, not-yet-retired transactions, including a currently exposed output. It updates on allocation and retirement edges and is meaningful throughout normal operation. |
| Rejection diagnostic | `c_rejected` becomes one for the clock interval after a rejected completion. It can remain high across consecutive rejections. It is an event diagnostic without READY and does not stall other traffic. |

The allocation source holds VALID and metadata stable until accepted. Each
completion source similarly holds its fields through its transfer edge. Output
VALID, metadata, data and error remain stable under backpressure; invalid output
fields and `a_tag` outside an allocation handshake are unspecified. All data and
metadata are opaque unsigned bit fields with no imposed fixed-point format.
`c_error` is stored and retired unchanged; it does not discard or reorder a
transaction. Every retired result is one complete transaction, so no LAST/frame
marker is present. Parameters are the only configuration and take effect at
elaboration. There is no external memory port, byte address, or bus error code.

Tags are reused only after retirement. An unallocated tag, an encoded tag
outside `0..DEPTH-1`, or another completion for a currently completed allocation
is rejected. A completion for a new tag on the **same edge as its allocation**
is also rejected; the earliest valid worker completion is the next edge.
Duplicate completions cannot overwrite an already completed or exposed result.
Tags contain no generation number: a stale completion arriving after that slot
has been retired and allocated again cannot be distinguished from its new work.
The worker contract is one valid completion per allocation, no completion before
allocation, and no stale completions after retirement/reset. This is a transaction
ownership contract, not a detector for an arbitrarily malfunctioning worker.

Allocation backpressures only when all slots are occupied. A full buffer can
retire and allocate on the same edge, reusing that slot safely. Completion and
allocation can proceed together for different live transactions. Results and
metadata are fetched synchronously into one output register after the oldest
completion has arrived. With an otherwise empty output and the head completing
on edge E, output-valid asserts after edge E+1; earliest retirement is E+2.
Already completed consecutive results retire at most once every two clocks.
A stalled output or missing older completion can delay progress indefinitely.
No autonomous timeout, cancellation, speculative rollback or packet assembly is
implemented. A scheduler should allocate only when it can dispatch the work.

## Parameters and structure

| Parameter | Legal values | Default |
| --- | --- | --- |
| `DEPTH` | 1..64, including non-powers of two | 8 |
| `DATA_W` | 1..256 | 32 |
| `META_W` | 1..64 | 16 |

Tag width is `max(1, ceil(log2(DEPTH)))`; count width is
`ceil(log2(DEPTH+1))`. Illegal parameter values fail elaboration with a named
parameter-error module. Head and tail explicitly wrap at DEPTH, so non-power-of-
two capacities have no inaccessible holes.

There are two arrays: `DEPTH*META_W` metadata bits and
`DEPTH*(DATA_W+1)` result/error bits. Each array has one synchronous write and
one synchronous read port, and no array reset. Only a completed head can be
read, and that allocated slot cannot be written concurrently with the read.
No read-during-write collision behavior is required. Ownership and completion
bitmaps reset independently from the payloads. This is compatible with generic
RAM inference; actual mapping of small arrays remains tool dependent.

Qualitative resource risk is **LOW** at defaults (392 logical payload bits,
49 output payload register bits, small pointers and bitmaps). At maximum sizes,
20,544 logical payload bits plus wide output storage, tag decode and bitmap
selection have **MEDIUM** implementation risk until mapped. No multiplier,
divider, DSP, vendor primitive, external memory or CDC structure is required.
Storage grows linearly with DEPTH and payload widths. These are structural
estimates, not measured LUT counts, BRAM use, frequency, power or throughput in
hardware. The two-clock retirement interval is an RTL scheduling property.

## Offline use and validation

`files.f` is the full production dependency closure. No includes, ROM images,
coefficient generators or downloaded source are required. From this directory:

```text
iverilog -g2012 -Wall -tnull -s ordered_completion_buffer -f files.f
```

`examples/ordered_worker_results.sv` shows an eight-entry scheduler/result
connection with a 16-bit request ID and 32-bit worker result. It exposes the
submission, tag, completion and retirement interfaces for integration; callers
must honor the allocation/worker-dispatch coordination described above.

From the repository root, run:

```text
python -B cores/system/ordered_completion_buffer/check.py
```

The runner prefers the repository OSS CAD Suite, with `IVERILOG`/`VVP` environment
overrides available. Every tool subprocess has a 20-second timeout. A failed run
replaces prior evidence and cannot leave a stale PASS report. Generated simulator
images use a task-specific `TemporaryDirectory` and are removed on exit.
`verification.json` retains commands, results and SHA-256 values for the exact
production source, example, TB, runner, file list and local LF attributes.

The testbench's oracle is a submission-order list of observed allocation tags,
metadata, completion values and completion status. It does not predict physical
ring pointers or inspect internal RTL state. Four configurations cover
DEPTH/DATA_W/META_W = 1/1/1, 3/8/5, 8/32/16 and 17/64/32. Finite checks include
reverse completion order, rejection of unallocated/duplicate/out-of-range and
allocation-edge completions, full-buffer backpressure, simultaneous retirement
and slot reuse, concurrent completion/allocation, arbitrary result/error fields,
independent output stalls and field stability, pointer wrap, reset of a held
completed head plus unfinished followers, and post-reset recovery. Four illegal
parameter declarations are rejected. The checks are deliberately finite.

Recorded maturity: **LINT_PASS** (Icarus syntax/elaboration), **UNIT_SIM_PASS**,
**HW_UNVERIFIED**. The example is an **INTEGRATION_CANDIDATE**. Synthesis, PnR,
STA, full regression and hardware checks were NOT_RUN; no historical hardware
results are attached to this version. See `SOURCES.md` for reuse and license
review. All package files use LF so Git text normalization preserves evidence.

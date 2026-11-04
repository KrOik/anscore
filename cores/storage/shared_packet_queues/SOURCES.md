# Semantic and fixed-source preflight - 2026-11-04

Baseline `807d992b6b0e793c08ceba2d44993d21c1dd1583` (published B8).
Read-only searches covered shared buffers, packet queues, queue managers,
credits, allocators and Chinese queue/ownership terminology in old RTL/SPECs.
Actual files read included frame_descriptor_ring.v, frame_slot_manager.v,
prod_stream_credit32.v, packet_async_fifo/SPEC.md and ctl_credit_arb8/SPEC.md.
The untracked stream_frame_commit README was also inspected for semantic
comparison only; it is not a dependency or adopted source.

The old descriptor ring is a single fixed-capacity FIFO. The DMA slot manager
owns four equal slots with writer/reader publish/release. The async packet FIFO
permits one packet in flight across clocks. Scalar credit32 adds/spends one
ledger, and credit_arb8 chooses grants without payload storage. Frame_commit
uses two complete-frame banks rather than a multi-queue shared cell pool.
Buddy allocation returns power-of-two address ranges and does not store FIFO
packets. None supplies independent complete-packet queues sharing one payload
pool, private per-packet reservation with whole-packet rollback, selected POP
with per-handshake credit, and selected-queue FLUSH. No old interface or source
is modified and no renamed arbiter/FIFO is introduced.

## Actual external source and full license inspected before RTL

Repository [alexforencich/verilog-axis](https://github.com/alexforencich/verilog-axis)
was pinned to commit `48ff7a7e2ef782cf778d47910cf85835c64b1bce` through the GitHub
API. Actual fixed-commit content was decoded and read in full:

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [COPYING](https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/COPYING) | dc298464e7aade999ebfa48632f6af2779439bcb | 1062 | 8ea57f95365e9b16a5b516f422b71269183a1ae53bab5878ae6d69039e58fe77 |
| [rtl/axis_fifo.v](https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/rtl/axis_fifo.v) | dfa465792f052486ac6f8d4c483318d4a338076d | 21692 | aefddc67fc3552d919280424606fc6b048e61d7df9ee7ee0f8801c082c1cfc39 |

The full COPYING is MIT, copyright 2014-2018 Alex Forencich; the source header
has MIT and copyright 2013-2023. Its frame FIFO uses speculative/committed write
pointers, optional oversize/bad-frame drops and an output pipeline for one
ordered ring. That provides a useful frame-publication comparison, not this
multi-queue free-list ownership interface. This RTL is an original serialized
linked-cell implementation with explicit queue selection and command responses.
No source, comments, tests or implementation were copied, adapted, translated,
executed or distributed. There is no AXI FIFO API/bitwise-compatibility claim.
External text was untrusted reference data, not task instructions.

Two Python urllib TLS attempts failed before reading content. Read-only
PowerShell HTTPS API requests with 15-second limits successfully fetched the
commit, source and full license. No remote build, script, installer or executable
was invoked. Upstream downloads are not needed by offline users.

All local RTL, wrapper, tests, independent packet-list oracle and prose are
original Apache-2.0 repository work. LICENSE is a local copy of the root
Apache-2.0 text for standalone use; no external copyright-bearing source or
license needs redistribution. There are no upstream modifications or sibling,
untracked, include, generated-memory, vendor or runtime source dependencies.
The complete production closure is the one local core plus optional wrapper.

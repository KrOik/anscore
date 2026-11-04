# Semantic and external-source preflight - 2026-11-04

Baseline: `99b5c8c1b3530775bb9dca0e5b4d1df07a014f68` (published B7).
Read-only RTL and README/SPEC searches covered buddy, allocator, free list,
memory/buffer pool, dynamic/variable-size storage and Chinese allocation terms.
The actual `cores/storage/buffer_dma/rtl/frame_slot_manager.v` was read: it
manages four equal physical DMA slots with WRITING/QUEUED/READING lifecycle,
publish/release and two writer/reader ownership. It cannot split, merge or
return variable-size address ranges. `ordered_completion_buffer` manages work
tags with issue-order retirement; cache allocates fixed lines internally.
Atomic/ECC scratchpads, memmove, multicast and hash-table services have separate
contracts. No existing general variable-size power-of-two address-pool command
interface was found. No old files or shared interfaces are modified.

Before RTL implementation, the GitHub contents API was used read-only to inspect
actual source and the full license at a fixed commit. No upstream scripts,
builds or executables were run. An initial `LICENSE` request returned not-found;
the fixed-commit directory listing identified `LICENSE.md`, which was then read.
The web-search endpoint was unavailable, so direct primary repository API reads
provided the actual pinned content.

Repository: [evanw/buddy-malloc](https://github.com/evanw/buddy-malloc)
Commit: `254531aa101806ee665166920bd4c70e88730eb1`.

| Actual inspected file | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE.md](https://github.com/evanw/buddy-malloc/blob/254531aa101806ee665166920bd4c70e88730eb1/LICENSE.md) | `b1d193a04c5bfc351ae7efbbbf233a9f336dd607` | 1052 | `ba54836ca9b4c01801ae5156d1674c98be6d15167cc76fcd61185c7d88572c23` |
| [buddy-malloc.c](https://github.com/evanw/buddy-malloc/blob/254531aa101806ee665166920bd4c70e88730eb1/buddy-malloc.c) | `d8d6bd387a8a7384efdd39ac39f3d660e3d3b122` | 16662 | `32a122e392182908c03e5415f86ac51d36b1b2235aec8988053afabffa1d7f1a` |

The actual license is MIT, copyright 2018 Evan Wallace. Its source uses bucket
free lists threaded through payload, 8-byte size headers, an XOR split bitmap,
dynamic heap growth through brk/sbrk and LIFO reuse. These are not adopted. The
reference establishes the split/merge capability and storage tradeoff; this
original RTL instead uses a fixed logical pool, synchronous explicit-state /
maximum-available-order metadata, deterministic lowest address and validated
base/order release. No upstream implementation, comments, tests or license text
is copied or redistributed. No C/POSIX/GitHub runtime dependency exists.
External files were reference data only; any agent-like instructions in them
would not be task instructions.

All local RTL, wrapper, testbench, interval oracle and prose are original
repository Apache-2.0 work. The included LICENSE copies the repository's
Apache-2.0 license for standalone offline use. No third-party implementation
requires a redistributed notice. No external/local upstream modifications,
sibling source dependencies, untracked dependencies, generated memory tables,
ROM files, vendor primitives or build-time generators are needed. Only the
one local RTL and optional local wrapper form the production closure.

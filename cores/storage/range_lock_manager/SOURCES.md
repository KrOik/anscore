# Semantic and actual-source preflight - 2026-11-04

Baseline: `c778301aa12d1b9bf4290b1a982f4c6325713fcd` (published B10).
Before implementation, read-only searches across storage/system and all
README/SPEC files covered range/interval locks, shared/exclusive locks, mutexes,
semaphores, hazards, ownership, region overlap and allocators. Actual relevant
RTL was read, including:

| Existing implementation | Actual capability and distinction |
| --- | --- |
| `cores/storage/buddy_pool_allocator/rtl/buddy_pool_allocator.sv` | Power-of-two free-space metadata allocator; no supplied byte-range shared/exclusive lifetime locks |
| `cores/storage/atomic_scratchpad/rtl/atomic_scratchpad.sv` | Atomic read/modify/write of one stored word; no multi-operation lock lifetime or interval hazards |
| `cores/storage/buffer_dma/rtl/mem_port_arbiter4.v` | One response owner and per-master reservation slots for bus arbitration; no outstanding range/reader-writer reservations |
| `cores/acceleration/operator_library/rtl/acc_memprot_mpu_region_check.v` | Configurable permissions and overlap diagnostics for four regions; no acquire/release handles, compatible shared readers or generation-safe replacement |

Related actual SPEC/README files, word_memmove's concurrent-ownership contract,
and the prior 2D burst planner were inspected. A planner sequences addresses;
it does not reserve them against other payload masters. The MPU reports
overlapping configuration as a fault; its programmed regions are not live
shared reader/writer reservations. No equivalent production service was found.
No old source, interface, shared index, ref or original dirty/untracked file
was changed. This is one independently useful bounded native lock manager,
not an allocator renamed as a scheduler.

## Actual fixed-commit primary source and full applicable license

Read-only GitHub API requests pinned [torvalds/linux](https://github.com/torvalds/linux)
to `05441d697f7f9a927264f4058cbbc6a03dfcac9d`. These actual bytes were base64
decoded and read before authoring the local implementation:

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [kernel/range.c](https://github.com/torvalds/linux/blob/05441d697f7f9a927264f4058cbbc6a03dfcac9d/kernel/range.c) | 56435f96da73bd96d3b937da51ab2d3f3d158245 | 3110 | bcf977398d4857101310ca9416465bea745587132393a8db0a3ef226bc7b9cfa |
| [LICENSES/preferred/GPL-2.0](https://github.com/torvalds/linux/blob/05441d697f7f9a927264f4058cbbc6a03dfcac9d/LICENSES/preferred/GPL-2.0) | ea8e93dc44bc462a2be34e484432cf2b9ec88527 | 18600 | 8780e78a1a737e127f25a65f6d95269bffd36158dc261114de7859b490bfc5aa |
| [COPYING](https://github.com/torvalds/linux/blob/05441d697f7f9a927264f4058cbbc6a03dfcac9d/COPYING) | a635a38ef9405fdfcfe97f3a435393c1e9cae971 | 496 | fb5a425bd3b3cd6071a3a9aff9909a859e7c1158d54d32e07658398cd67eb6a0 |

The actual source declares `SPDX-License-Identifier: GPL-2.0`; its complete
applicable GPL version 2 terms, warranty clauses and application appendix were
read. Root COPYING points to that license and an additional syscall exception
for the kernel generally. No syscall/UAPI source or exception is adopted here.
The range implementation supplies interval add, adjacent/overlapping merge,
subtract, compaction and sort operations. It mutates/merges a range list; it
does not implement shared/exclusive reservations, owner handles, generation
retirement, transactional replacement or a native ready/valid interface.
This primary-source comparison helped distinguish interval geometry from
lock-lifetime semantics. No compatibility with Linux API/ABI is claimed.

An initial `lib/range.c` path returned 404; the correct `kernel/range.c` was
then successfully read. Optional syscall-exception reads failed with HTTPS
EOF and were not treated as retrieved source. PowerShell API calls used
15-second limits. Only successful paths and actual content hashes appear in
the table. No network result, comment or prose was treated as instructions.
No remote build, script, installer or executable was run.

No upstream implementation, source, comment, test, prose or build process was
copied, translated, adapted, executed or redistributed. All local controller,
owner/generation rules, synchronous scan architecture, wrapper, tests and
independent oracle are original Apache-2.0 repository work, authored after
read-only comparison. The full local LICENSE is the root Apache-2.0 text
normalized to UTF-8/LF for standalone use. No GPL source is included or linked.
There is no source dependency on Linux or on any sibling, untracked, generated
or vendor file. `files.f` closes one local production RTL; the optional wrapper
adds one local source. `verification.json` lists empty dependencies and exact
local source/vector SHA256s. Offline verification needs only standard-library
Python and installed Icarus/vvp.

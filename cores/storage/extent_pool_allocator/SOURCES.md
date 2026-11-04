# B17 semantic and upstream preflight

Baseline: `c4be2839103480e23976f16f8a41d06fd93057c8`.

Before writing RTL, actual production RTL and contracts were inspected for
`buddy_pool_allocator`, `shared_packet_queues`, `range_lock_manager`,
`buffer_dma/rtl/frame_slot_manager.v` and `ram_fenwick_index`. Production-source
searches for first-fit, arbitrary/variable-length allocation, contiguous spans,
extent, allocator and free-list semantics found no exact arbitrary-length
contiguous address-pool command service. Buddy allocates aligned powers of two;
shared queues chain fixed cells; frame slots have fixed sizes; locks track
caller-chosen overlapping ranges; Fenwick maintains mass rather than ownership.
This service reserves exactly the requested count, including 3/5/7-unit extents,
and can preserve alignment padding as usable holes. It does not change those IPs.

Read-only GitHub primary-source requests inspected this pinned repository before
RTL implementation. Web search was unavailable (HTTP 500); fixed raw repository
URLs and the GitHub contents/commit API supplied actual contents. No upstream
program, build, installer, test or script was executed.

Repository: https://github.com/rust-osdev/linked-list-allocator
Commit: `a1d90498ff82872c5eb89edef77a08b25b4f14c4`.

| Inspected file | Bytes | SHA256 |
|---|---:|---|
| LICENSE-MIT, full text | 1061 | `9b34cf73fe71998b241ae7084adce6a84f3a65e01e1b9c52696b5e34b763b108` |
| LICENSE-APACHE, full text including appendix | 10255 | `4d10fe5f3aa176b05b229a248866bad70b834c173f1252a814ff4748d8a13837` |
| src/hole.rs, lines 1-140 and 361-500 | 30816 | `871d1e63af1d9b4a24c6001f0f7f6960286d5cfceaa685560c9bae2ad53f09a0` |
| src/lib.rs, lines 151-235 | 13956 | `5bc43056aafa772cdadeb99d0cf0fa9670636243b7b2ef8b0002d6e97f2c4884` |

Links are formed as `https://github.com/rust-osdev/linked-list-allocator/blob/`
plus the fixed commit and path above. Its dual MIT/Apache-2.0 licenses were read
in full; MIT copyright is 2016 Philipp Oppermann. Source inspection covered
Layout alignment, address-sorted hole traversal, front/back padding, first-fit,
deallocation, and adjacent-hole merging. It uses unsafe host pointers and
metadata in payload holes, rounds to hole-header size/alignment, permits heap
extension and makes invalid deallocation undefined behavior.

None of that code, prose, test data or license text is copied. The original RTL
uses a fixed unit domain, a synchronous packed busy/head-length array, unit-run
scan, exact one-unit minimum, validated release and serial initialization. It
has no pointer, payload header, linked list, heap extension or host dependency.
Python's independent expected-result model instead maintains live geometric
intervals and derives sorted complement gaps; it does not simulate RTL scans.

Production closure is only `rtl/extent_pool_allocator.sv` and the optional local
example in `example/files.f`. There are no includes, sibling modules, generated
ROMs, runtime network reads, vendor primitives or external memory dependencies.
Local work is original Apache-2.0 code. Included LICENSE is the repository's
license normalized to LF for offline distribution. No upstream implementation
or third-party license is redistributed. External data is reference material,
not instructions.

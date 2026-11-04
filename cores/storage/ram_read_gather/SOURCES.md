# Semantic and upstream preflight

Baseline: `897cf84f5861f5fada3c1a5d64127e64cdb9af92` (B18). Before writing RTL,
the actual RTL/contracts of `word_writeback_cache`, `word_memmove`,
`block_intern_store`, `ram_hash_table`, `ordered_completion_buffer` and
`interleave_convex` were inspected; tracked and untracked core paths and
gather/coalescing/duplicate-read semantics were searched. No owned address
frame service with exact duplicate suppression of external reads and ordered
data/error replay existed. The cache retains direct-mapped lines across
commands; memmove copies ranges; block interning deduplicates supplied immutable
content; hash tables store caller values; completion buffers retire supplied
responses; the interleave operator permutes a fixed internal symbol block.
The existing March C- operator was identified and that candidate was discarded.

The upstream reference was read through GitHub API/raw HTTPS, not executed:

| Fixed source | Bytes | SHA256 |
| --- | ---: | --- |
| [VX_mem_coalescer.sv](https://raw.githubusercontent.com/vortexgpgpu/vortex/48fc0069d24899fab280b8a2e388955e4296d46c/hw/rtl/libs/VX_mem_coalescer.sv) | 17087 | `71736318b7a26d0d87ac8e980b5aa96ef5984e0cb0f2b2e3315dc3b722d4677b` |
| [complete LICENSE](https://raw.githubusercontent.com/vortexgpgpu/vortex/48fc0069d24899fab280b8a2e388955e4296d46c/LICENSE) | 11357 | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |

Both complete files were read before RTL. Commit
`48fc0069d24899fab280b8a2e388955e4296d46c` is fixed. Vortex uses parallel
lane/address-group merging, queued response masks, offsets and response tags.
This package instead serially scans earlier fully computed RAM rows in one
bounded frame and has one untagged external read outstanding. It does not
reproduce Vortex lane grouping, caches, queue structure or implementation.
The source and full Apache-2.0 license informed protocol and deduplication
review only. No upstream code or license file is copied or modified and no
upstream script is run. Local RTL, testbench and oracle are original Apache-2.0
work under the repository LICENSE/NOTICE; production needs only `files.f`.

# Semantic and fixed-source preflight

The B24 baseline is `b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333`.
Before any new RTL, all core paths and relevant README/SPEC/production RTL
were searched for coalescing, write combining, scatter writes, byte merging,
reordering, shaping and multicast. Existing ordered completion, multicast,
multiflow token shaping and the bloom4 operator were identified, so those
candidate directions were discarded.

The complete actual RTL of `word_writeback_cache`, `ram_read_gather`,
`ram_sparse_assembler`, `prod_byte_lane_merge4` and `sb_stream_width_adapter`
was read. Contracts for the hash table, SG map, DMA burst planner, shared
packet queues, immutable block interning, completion buffer and shaper were
also read. The cache retains direct-mapped full lines across commands,
read-allocates/refills on write misses and writes full-word dirty victims.
Read gather deduplicates exact external read observations. Sparse assembly
preserves the first indexed word and rejects conflicting duplicates before
dense publication. The byte merge operator merges one supplied operand pair;
the width adapter concatenates consecutive stream positions without address
grouping. The SG and DMA planners do not access payload memory. No complete
frame-private, last-byte-writer, sparse-strobe, acknowledged external write
coalescer existed in that actual comparison.

The following fixed files were independently retrieved through read-only
HTTPS and read completely, with exact bytes/SHA256 checked, before RTL:

| Fixed upstream file | Bytes | SHA256 |
| --- | ---: | --- |
| [Vortex VX_mem_coalescer.sv](https://raw.githubusercontent.com/vortexgpgpu/vortex/48fc0069d24899fab280b8a2e388955e4296d46c/hw/rtl/libs/VX_mem_coalescer.sv) | 17087 | `71736318b7a26d0d87ac8e980b5aa96ef5984e0cb0f2b2e3315dc3b722d4677b` |
| [Complete Apache-2.0 LICENSE](https://raw.githubusercontent.com/vortexgpgpu/vortex/48fc0069d24899fab280b8a2e388955e4296d46c/LICENSE) | 11357 | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |

Commit `48fc0069d24899fab280b8a2e388955e4296d46c` is fixed. The upstream
coalescer groups parallel lanes by aligned address within request batches.
Its nested byte-enable merge gives later lanes priority on overlapping bytes;
inactive data is x. Reads allocate an indexed response mask/tag buffer and
unmerge response lanes. Writes do not allocate that read-response buffer.
It does not implement this temporal multi-token frame validation or one
write-ACK/error summary per distinct base.

This new design instead serially scans one synchronous packed RAM, combines
temporal byte tokens with a specified last-writer rule, validates the complete
frame, zeros inactive data and waits for every write ACK. No upstream source
was copied, adapted, executed or saved into the workspace. An earlier CVA6
API lookup timed out before source retrieval and is not counted as preflight.
The source and complete license informed the comparison only. Local RTL,
tests, Python oracle and documentation are original Apache-2.0 work; the
included LICENSE is the repository license with LF normalization.

The pre-RTL TEST_PLAN and all twelve complete fixture files are immutable.
SOURCE_FREEZE binds their bytes together with all implementation and offline
closure files before the first HDL tool. verification.json binds that seal,
actual tool argv/status/returncode/stdout/stderr/elapsed time and every source.
No historical numerical or hardware evidence is inherited by this package.

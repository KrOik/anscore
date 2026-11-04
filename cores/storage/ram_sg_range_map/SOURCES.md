# Semantic and fixed upstream preflight

Baseline `ff2aadf8ebdc8e5475b7022cd68d47e496b9f593` (B19), including its 38
protected stable refs and unchanged original worktree. Actual tracked/untracked
source searches and RTL/contracts were inspected before implementation:

- `dma_2d_burst_plan` plans regular strided rows and beat/page masks; it has no
  stored arbitrary segment map or reusable logical-range queries.
- `frame_word_dma`, `cip_dma_descriptor_chain` and extended-library `dma_sg`
  move payload along contiguous or chained src/dst descriptors. They do not
  publish a reusable SG map or query an arbitrary logical subrange.
- `ram_prefix_table` chooses the longest bit prefix, not concatenated segment
  offsets. `ram_read_gather` deduplicates discrete external reads, not ranges.

No equivalent atomic map replacement plus repeated range-to-span service was
found. This is an address-planning service; a consumer can feed each physical
span into a bus burst planner or payload engine using an explicit adapter.

Full upstream files were read by fixed raw HTTPS, without execution, before
RTL. The initial combined display truncated the source; the complete source
was subsequently read alone to close that gap.

| FreeBSD commit `e9e4115a0bb41416bf5e1277627fc6c565073972` | Bytes | SHA256 |
| --- | ---: | --- |
| [sys/kern/subr_sglist.c](https://raw.githubusercontent.com/freebsd/freebsd-src/e9e4115a0bb41416bf5e1277627fc6c565073972/sys/kern/subr_sglist.c) | 23728 | `27748fbe96bba1270c8cbf859527c78efa7f9352defb6cf91f1ef7214b4edfa5` |
| [complete COPYRIGHT](https://raw.githubusercontent.com/freebsd/freebsd-src/e9e4115a0bb41416bf5e1277627fc6c565073972/COPYRIGHT) | 6070 | `d714467a37d231cd5e630f09eacb134d6936e74940836129309ed20d796ca790` |

The complete C source includes its full BSD-3-Clause license. Its append,
rollback, split, join and logical slice routines were reviewed. The aggregate
COPYRIGHT, including the historical BSD license and advertising-clause removal,
was also read in full. This local original Apache-2.0 implementation uses a
fixed dual-bank synchronous RAM and all-or-nothing table publication, without
kernel allocation, VM pages, source-level adaptation or copying. No upstream
code/license text/script is redistributed or executed. Repository LICENSE and
NOTICE apply; there is no production sibling, vendor or network dependency.

# Source, semantic review and license record — 2026-11-04

Development baseline: `6d1af43` on `development/ip-assets-20261104`. Existing
stable refs and dirty assets outside this new package were left unchanged.

Local semantic review searched RTL and README/SPEC text under `cores/` for
tag allocation, out-of-order completion, transaction reorder, retirement and
related queue operations. Important comparison boundaries:

- `cores/system/common_scaffold/memory/README.md` explicitly excludes command
  queues and multi-ID/out-of-order response handling from its native DMA.
- `cores/storage/buffer_dma/rtl/mem_port_arbiter4.v` has four reserved owner
  response slots but only one backend request in flight; it routes responses
  to masters and does not retire arbitrary tagged completions in issue order.
- `cores/system/common_scaffold/stream_bus/axi_multi_crossbar/README.md` limits
  outstanding work to one transaction per master/direction and per target/
  direction. Captured-owner response routing is a different operation.
- `cores/system/common_scaffold/image/raster_blocks` reorders image coordinates,
  rather than transaction completions. `binary_heap_queue` orders by priority,
  rather than original issue order. Stream multicast and width conversion do
  not provide this allocation/completion/retirement capability.

External candidate searched and pinned read-only before implementation:

| Field | Record |
| --- | --- |
| Repository | https://github.com/alexforencich/verilog-pcie |
| Fixed commit | `25156a9a162c41c60f11f41590c7d006d015ae5a` |
| License | MIT, `COPYING`, copyright (c) 2018 Alex Forencich; fetched and checked |
| Source compared | `rtl/dma_if_pcie_rd.v`, source copyright (c) 2021 Alex Forencich |
| Relevant structure | PCIe tag table, operation table, active tags and completion status handling |
| Decision | Reference for a mature tagged operation boundary; no PCIe dependency or source copied. Independently implement a narrow generic buffer instead. |
| Imported files / local adaptations | None / none |
| Additional third-party dependencies | None |

GitHub API/raw retrieval used Python `urllib.request` after PowerShell HTTPS
requests failed intermittently. The first guessed `rtl/pcie_tag_manager.v`
path returned 404 and was not used. The pinned recursive tree then identified
the actual `rtl/dma_if_pcie_rd.v` operation/tag tables, read for comparison after
the independent RTL draft. Only repository metadata/license were needed for the
initial candidate decision. No fetched external build or installation commands
were executed and external text was never treated as agent instructions.

Pinned primary files:

- [MIT COPYING](https://github.com/alexforencich/verilog-pcie/blob/25156a9a162c41c60f11f41590c7d006d015ae5a/COPYING)
- [PCIe read DMA tag/operation tables](https://github.com/alexforencich/verilog-pcie/blob/25156a9a162c41c60f11f41590c7d006d015ae5a/rtl/dma_if_pcie_rd.v)

All delivered RTL, example, TB and runner are original ANSCORE code under the
repository's Apache-2.0 LICENSE. No third-party notices are needed for unadopted
reference code. `files.f` plus its listed source is the complete offline RTL
dependency closure. Online references are not required to compile or use it.

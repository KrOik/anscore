# Source and capability review — 2026-11-04

Baseline: `e711afc` on `development/ip-assets-20261104`. Only this new package
was changed. Existing stable refs and shared RTL were preserved.

Pre-development semantic search covered `memmove`, overlap-safe movement,
backward/reverse copies and source/destination overlap in production RTL and
README/SPEC files. The existing
`cores/system/common_scaffold/memory/README.md` explicitly rejects nonidentical
overlapping descriptor source/destination ranges (status 9), while allowing
same-range copies. The 2D video DMA moves memory/stream data, not an overlapping
memory-to-memory range. The linear frame word DMA likewise implements stream
reads or writes. This package's independent increment is preserving the original
source snapshot for arbitrary aligned overlapping word ranges.

Read-only external candidate reviewed before implementation:

| Field | Record |
| --- | --- |
| Repository | https://github.com/alexforencich/verilog-axi |
| Fixed commit | `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` |
| License | MIT; full `COPYING` fetched and checked, copyright (c) 2018 Alex Forencich |
| Source examined | `rtl/axi_cdma.v`: central-DMA descriptor and AXI memory-channel interface |
| Decision | Broad DMA candidate comparison only. Implement a narrow original acknowledged-word overlap-safe mover instead of importing an AXI stack. |
| Adopted external files / adaptations | None / none |
| Additional external dependencies | None |

Pinned primary references:

- [MIT COPYING](https://github.com/alexforencich/verilog-axi/blob/516bd5dadc3365b7f9e225d2af8fe0b8d804fe53/COPYING)
- [Central DMA source](https://github.com/alexforencich/verilog-axi/blob/516bd5dadc3365b7f9e225d2af8fe0b8d804fe53/rtl/axi_cdma.v)

Repository metadata, license and source were read using HTTPS. No upstream
installation/build scripts ran. External text was treated as reference data.

The original connection example reuses these existing ANSCORE sources unchanged:

- `cores/storage/buffer_dma/rtl/mem_port_arbiter4.v`
- `cores/storage/buffer_dma/rtl/mem_port_bram.v`

`buffer_dma/LICENSE_DEPENDENCIES.md` identifies the backend and arbiter as locally
authored, with no embedded external third-party RTL. Its final paragraph retains
a historical statement that redistribution terms had not yet been assigned.
This delivery relies on the current root `NOTICE`/`LICENSE` and README, which
apply Apache-2.0 to the authors' original contributions; it does not remove the
old record or relabel third-party code. Both dependencies are in the tracked
baseline. Their working
bytes were checked against their baseline Git blobs and match exactly; the
verification report binds their SHA-256 values independently of new source.
`examples/files.f` records their full relative source closure. The standalone
core's `files.f` has no dependency outside this package.

All new source, examples and validation code are original ANSCORE contributions
under the repository Apache-2.0 LICENSE. Reused local files retain their existing
license and history. No online repository is needed to compile or validate the
delivered core or the example when their listed local dependencies are retained.

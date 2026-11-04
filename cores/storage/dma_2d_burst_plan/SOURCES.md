# Semantic and fixed-source preflight - 2026-11-04

Baseline: `e2ccd5380052e92a5430e97b6fdbf0621a17503c`, published B9.
Read-only searches of storage, system and communication RTL/README/SPEC files
covered bursts, 4 KiB boundaries, strides, scatter/gather and DMA ownership.
Actual matching RTL was read, not inferred from names:

| Actual old file | SHA256 at preflight | Capability boundary |
| --- | --- | --- |
| `cores/system/utility_library/rtl/prod_burst_split4k.v` | 7013f52edc84e33461b8fc306f31ca626d0ad4c1972175befd9a18033618c347 | One scalar `min(remaining,max,bytes_to_4K)` result with CE; no descriptor ownership, sequence or masks |
| `cores/system/utility_library/rtl/prod_address_boundary4k.v` | ffde78915e0b96060a1703fde8af3836fd103b41f8508378ffe432ca692e8d05 | Reports one scalar 4K crossing/address-wrap condition |
| `cores/storage/buffer_dma/rtl/frame_word_dma.v` | 63eea588281d588c2f5c74d52ae6669bd318b95c1044407836d21d8cacfc0920 | Aligned full-word single-descriptor request/response mover, no bursts or partial lanes |
| `cores/system/extended_library/src/dma_sg.v` | 19130c447f401c8d30fa6c74269f5c1f8e3ea58df3eecf31747c345b375916f7 | Register-loaded contiguous full-word A/B local RAM transfer with direction; no external descriptor list or signed 2D stride |

The related SPEC/README files were also read. Other address-generation search
hits were FFT butterflies, symbol permutations, MPU permissions and AXI-Lite
window decoding. Existing memmove documentation explicitly excludes bursts
and partial transactions. None provides a byte-oriented 2D row sequence with
signed row-start stride, whole-descriptor range rejection before any prefix,
aligned max-beat/page plans, exact edge masks and logical row/global offsets.
The new package is an original complete planner, not a renamed scalar splitter
or a claim that a payload-moving DMA master has been implemented. No old file,
interface, index, ref or original dirty/untracked work was modified.

## Actual external source and full license read before implementation

Read-only GitHub API requests resolved and pinned the primary repository
[alexforencich/verilog-axi](https://github.com/alexforencich/verilog-axi) to
`516bd5dadc3365b7f9e225d2af8fe0b8d804fe53`. The actual fixed-commit files were
base64-decoded and read in full, including the full permission/warranty text:

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [COPYING](https://github.com/alexforencich/verilog-axi/blob/516bd5dadc3365b7f9e225d2af8fe0b8d804fe53/COPYING) | 6923387c7569f15368fefc084c0f3c46e18e3622 | 1057 | ba81481b2d63a33e0dce336d9e736130709549feeaf6cd424b34beba712baa50 |
| [rtl/axi_dma_rd.v](https://github.com/alexforencich/verilog-axi/blob/516bd5dadc3365b7f9e225d2af8fe0b8d804fe53/rtl/axi_dma_rd.v) | 9e01f9b87498bfe9a9d25fff6aed64d5c844dfa0 | 29645 | 853ff3aedc44ec0c12ef3ae8b84d7559800d372f76832c7c133ed5eecac61dd8 |

Both carry MIT terms, copyright 2018 Alex Forencich. The actual source accepts
one-dimensional read descriptors, issues 4K/max-length-limited AXI read
requests, realigns unaligned payload data and queues stream output. Its
`ENABLE_SG` assertion explicitly rejects enabled scatter/gather as unsupported.
This was a useful primary-source comparison of burst/page/unaligned semantics.
It does not provide this signed 2D preflight-and-plan interface, and this
package does not claim source/API/bitwise compatibility with it.

No upstream source, comment, implementation, test or build command was copied,
adapted, translated, executed or redistributed. The original local controller,
mask decoder, serialized range preflight, wrapper, tests and byte-enumeration
oracle were authored after this read-only comparison. External content was
untrusted reference data, not instructions. PowerShell HTTPS GitHub API reads
used a 15-second timeout; no installer, remote script, simulation or build was
run. No fetched file is needed by offline users.

All local files are original Apache-2.0 repository work. `LICENSE` is the full
root Apache-2.0 text normalized to UTF-8/LF for standalone redistribution.
There are no adopted upstream modifications, runtime/network dependencies,
submodules, untracked dependencies, sibling RTL, generated memory files or
vendor primitives. The production closure is the one local core and, when
requested, the optional local fixed-parameter wrapper. Local source SHA256s
and an explicit empty dependency list are in `verification.json`.

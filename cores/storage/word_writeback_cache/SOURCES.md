# Source, semantic de-duplication and license review

Review performed before writing this package's RTL, 2026-11-04, against
development baseline `cf9b62d`. All production logic and tests in this directory
are original contributions covered by the root Apache-2.0 LICENSE and NOTICE.

## Semantic de-duplication

Searched production RTL and documentation for cache modules, write-back caches,
cache lines, dirty eviction, flush, storage, DMA and tag comparisons.

- `operator_library/rtl/acc_memprot_cache_tag_compare.v` manages four tags in a
  caller-supplied state vector. It has no payload RAM, memory port, refill,
  dirty writeback, byte merging or cache maintenance transaction.
- `buffer_dma` supplies direct native memory access, arbitration, BRAM, frame
  and descriptor movement. `word_memmove` supplies overlap-safe block copying.
  Neither retains transparent cached copies or dirty lines.
- `atomic_scratchpad` supplies indivisible operations on private local words;
  it is not a cache of an external memory address space.
- Ordered completion, multicast, stream FIFOs and image line buffers have
  different ordering/data-retention contracts.

The added capability is a transparent native-port write-back data cache with
whole-line allocation, byte writes, dirty eviction, flush+invalidate and
explicit backend-error recovery. It is not a width/channel variant of those IPs.

## External read-only preflight

No external code, scripts or build system is adopted or executed.

An initial cache candidate search targeted
<https://github.com/IObundle/iob-cache>. The GitHub `commits/master` and tree
API read, `git ls-remote`, direct Python urllib API read and one local-proxy read
failed with TLS EOF. Each HTTP request had a 15-second bound. The web search
tool separately returned HTTP 500. No SHA, source contents or license was
obtained for this candidate; therefore it was rejected as an implementation
dependency and no license claim is made for it.

A second read-only reference targeted the already known fixed revision
`516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` of
<https://github.com/alexforencich/verilog-axi>, specifically:

- `rtl/axi_ram.v` (memory response and byte-strobe interface reference)
- `COPYING` (license verification)

The fresh direct raw-content request failed with TLS EOF before obtaining
COPYING, so this preflight does not claim a fresh successful retrieval of either
file. A parallel read-only retry by the coordinator subsequently succeeded via
Python urllib, without an added proxy. It read the complete MIT COPYING
(copyright 2018 Alex Forencich), 1,057 bytes, SHA256
`ba81481b2d63a33e0dce336d9e736130709549feeaf6cd424b34beba712baa50`,
and `rtl/axi_ram.v`, 13,216 bytes, SHA256
`2eb669f3cd1fd912a74c024df3bea5765a3599eead1a007c63f19b6b185d55c4`.
The coordinator inspected the MIT header and AXI4 RAM interface/parameters
(`DATA_WIDTH=32`, `ADDR_WIDTH=16`, `STRB_WIDTH=DATA_WIDTH/8`, `ID_WIDTH=8`,
`PIPELINE_OUTPUT=0`). This is a memory-backend reference, not a cache algorithm.
The success was reported after original RTL construction had started; the
earlier failed preflight and root license review were recorded before RTL.
No upstream-derived RTL or external runtime source dependency was introduced.

## Unmodified local integration dependency

`examples/cache_scratchpad.sv` instantiates existing
`../buffer_dma/rtl/mem_port_bram.v`. Its native byte-addressed response protocol
was read before implementation; it is not modified. The root LICENSE/NOTICE
cover locally authored contributions. `buffer_dma/LICENSE_DEPENDENCIES.md`
retains historical unassigned-redistribution/open-L5 wording; inspect that
document together with the current root LICENSE and NOTICE. No historical
hardware evidence is extended to this cache composition.

## Architecture risks

Default `LINES=16, LINE_WORDS=4, TAG_W=8`: **LOW** resource risk. Data storage
is 2,048 logical bits, metadata 416 bits, and the data array has one shared
synchronous read/write address. Maximum `64 x 16`: 32,768 data bits plus
1,408 metadata bits, **MEDIUM** resource/timing risk. Tags/valid/dirty use
register arrays and an indexed comparator; reset fans out to validity bits,
not payloads. No multipliers, vendor primitives, external IP or CDC.

These are structural judgments, not measured utilization or clock frequency.
Reset discards dirty cache data; failed writeback retains the dirty line and
may already have written a prefix to memory. Ordinary idempotent RAM and
exclusive ownership of cached addresses are required. MMIO and coherent
multi-master use are outside the contract. All versions remain HW_UNVERIFIED.

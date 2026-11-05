# Source and license preflight

The package is original Apache-2.0 work; included LICENSE/NOTICE apply to
RTL, example, TB, Python mathematics and packaging. No third-party HDL or
oracle was copied, adapted or executed. Existing RAM-table packages informed
repository conventions and semantic deduplication only. The Apache license
text is the standard text already supplied by this repository.

## Read-only external reference

Repository: https://github.com/alexforencich/verilog-cam

Fixed commit: `69002598f12d7418d44bbaa88ea0be3bf3b14e6c` (2019-07-24).
Each file below was downloaded into memory and fully read, including COPYING,
before implementation. Content API reference:
`https://api.github.com/repos/alexforencich/verilog-cam/contents/{path}?ref=69002598f12d7418d44bbaa88ea0be3bf3b14e6c`.
No source was persisted into the package or run. This table records exact
decoded raw source bytes. The first raw README request failed with an SSL
timeout; the fixed-commit GitHub contents API then supplied the full content.

| File | Bytes | SHA256 |
|---|---:|---|
|COPYING|1062|6ba8587d3eb6a5e03469ef0099b2f3e4d655f5cd248c7b25f754098e0e464666|
|README.md|243|465f927ae355fa98a322d75e5d14d0e7293185032ca9584b3f9216b9501c6bd7|
|rtl/cam.v|3296|c57f8e5cde57e22d843a6758bfbbc259adc04825839b0c282bf3085555e5de2f|
|rtl/priority_encoder.v|3205|9eee1cc4d6bf910aeffe6c3fa5407763c0529bf2a07996ae67549953286ab2f7|
|rtl/cam_bram.v|7642|1f4afcb3b5b0a7bc2a2af20e219f30effd9e8749139567ae66c501b0b9eaadfc|
|rtl/ram_dp.v|2608|d50fd9dc65fb621f30c9b1c792875831557d113c65ecd1cf16c643da8f1b7d0f|
|rtl/cam_srl.v|6816|dbf8cf2061175d8126855544176cb9917447421b7bb2b5f129df485ec358705a|

COPYING is MIT, copyright2015-2016 Alex Forencich; individual headers include
2014-2018/2016. The full permission, attribution and warranty text was read.
The license permits reuse with notice; this package uses the source only as
an architectural comparison and does not distribute derivative upstream code.

The upstream wrapper selects parallel SRL or BRAM exact-match CAM banks.
BRAM uses slice lookup tables, erase RAM, delete/write phases and parallel
bitmap intersections. Its recursive priority encoder and dual-port RAM/init
behavior were examined. It supplies neither per-rule arbitrary care nor the
single-owner ordinary command/held-response contract here. Our implementation
uses one serial packed synchronous RAM port, one matcher and independently
reset live metadata. The independent string/set oracle is original Python.

## Repository semantic deduplication

All100 B25 manifest package introductions and storage command contracts were
scanned. Actual focused contracts/RTL were read for ram_prefix_table,
ram_region_guard and ram_hash_table; stream_pattern_match and existing AXI4
bridges/crossbars, descriptor DMA, ordered completion and shared packet queues
were compared. Repository searches found no equivalent arbitrary-care indexed
all-match rule bank. The arbitrary bit0-only 128-bit predicate distinguishes
this service from contiguous prefixes, intervals and exact-key tables.

No B25 package, published record or baseline HDL was modified or rerun.
The finite fixture audit uses only this package's generated immutable records.

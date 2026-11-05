# Provenance and semantic deduplication

All delivered RTL, example, TB and Python code were independently authored for
ANSCORE under Apache-2.0. No upstream RTL was copied/adapted/generated; no
remote build or install script was executed. No third-party source or runtime
dependency is required for production use. Python3/Icarus/vvp are test-only.
The package includes the full repository license.

Before implementation, read-only primary source and its embedded MIT license
were inspected at a fixed upstream revision:

- Repository: https://github.com/alexforencich/verilog-axi
- Commit: `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53`.
- File: [rtl/axil_adapter.v](https://github.com/alexforencich/verilog-axi/blob/516bd5dadc3365b7f9e225d2af8fe0b8d804fe53/rtl/axil_adapter.v).
- Use: understand existing open-source AXI-Lite width conversion interfaces;
  independent bounded downsizing-only implementation with explicit alignment,
  zero-strobe omission and response aggregation. No bit-equivalence claimed.

Semantic repository-wide RTL/README/SPEC searches inspected addressed width
conversion, AXI-Lite adapters, downsizing and existing packet/stream adapters:

- `sys_width_converter.v` compacts byte streams or packs bytes with LAST/USER;
  it carries no byte address, independent write channels or read responses.
- `sb_stream_width_adapter.v` and `stream_width_adapter.v` transform stream
  lanes, not addressed transactions; they cannot aggregate read data/errors.
- Existing full AXI and AXI-Lite crossbars route equal-width transactions.
  `axi_multi_crossbar` supports full AXI bursts but not interface downsizing.
- B31 `axil_timeout_bridge` preserves interface width and protects against
  missing responses. This package transforms access granularity, has no
  watchdog and can be composed with a guard when a larger integration needs it.
- Existing `ram_byte_write_coalescer` merges a complete frame of byte stores
  to aligned output words; it neither accepts AXI-Lite accesses nor splits
  wide reads/writes into individually acknowledged narrow target transactions.

Widths are parameters of this single capability; no width variant is counted
as a separate IP. The complete offline production source closure is exactly
`rtl/axil_width_downsizer.v`; file lists and a complete port-level example are
included.

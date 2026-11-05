# Provenance and semantic deduplication

All delivered RTL, TB, example and Python code were independently authored
for ANSCORE under Apache-2.0; see the package `LICENSE`. No third-party source
was imported, adapted, generated or vendored. There are no production
dependencies outside this package. Repository baseline during authoring:
`1d0afbd` (B30).

Before implementation, read-only primary upstream inspection was performed:

| Primary source | Pinned revision | Inspected file | License in inspected file | Usage |
| --- | --- | --- | --- | --- |
| https://github.com/alexforencich/verilog-axi | 516bd5dadc3365b7f9e225d2af8fe0b8d804fe53 | rtl/axil_register.v | MIT | Reference for five-channel AXI-Lite interface and buffering; no code copied |
| https://github.com/ZipCPU/wb2axip | 2e8d3bc2d26ddc33d1881022a2a2b9d3f0c16b9b | rtl/axilsafety.v | Apache-2.0 | Reference for timeout/fault-isolator capability; no code copied |

Both fixed-revision files were retrieved directly from GitHub raw for
read-only source/license inspection. The general web search tool returned
HTTP 500; direct primary-source retrieval succeeded. Inspection artifacts
were kept in tool output, not installed or executed. No remote scripts ran.

Semantic duplication review covered existing storage/system/communication
RTL and descriptions, excluding generated board/reference/history copies:

- `cores/system/stream_bus_library/rtl/sys_bus_timeout_monitor.v` is explicitly
  passive, counts timeouts and never fabricates a completion. It cannot keep
  an upstream AXI-Lite master progressing after a timeout.
- `cores/system/stream_bus_library/rtl/sys_axi_lite_interconnect.v` routes one
  master to four address windows and generates decode errors, but does not
  implement timeout ownership, sticky quarantine or late-response draining.
- `cores/system/common_scaffold/stream_bus/axil_multi_crossbar` arbitrates
  multiple masters and destinations, whereas this package protects a single
  slave connection with independent bounded service for read and write.
- `axil_csr_bridge` in the test shell adapts to a CSR command interface; it
  does not provide this timeout/quarantine behavior.

This addition contributes active local timeout responses, subsequent local
error service, and preservation/draining of the original transaction across
the timeout boundary. Different widths are parameters of one implementation.

Inspected upstream source SHA-256 (fixed revision, UTF-8/raw bytes):

- `rtl/axil_register.v`: `b58a923af874e3600727f214897cee868591487d8c00317603e5f232d9f2fa07` (6076 bytes).
- `rtl/axilsafety.v`: `100a621066f06466ba075759227cd8d5cff32e0b2acc6ea4e959fba182cfed51` (36645 bytes).

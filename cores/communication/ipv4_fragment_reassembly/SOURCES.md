# Sources and semantic boundary

Baseline: `1e9e9130cef71127d2c8d2762affe815b067b9f5`.
New RTL, example, oracle, vector generator, TB and runner are original Apache2
implementation. The bundled LICENSE supplies the full license. No upstream
source is copied, translated, imported or executed.

Before implementation, read-only searches and actual source/document reads
found: ethernet_udp/udp_payload_rx explicitly rejects fragments; Mold/ITCH
receiver processes application messages; ram_sparse_assembler requires a
known immutable object length and permits equal duplicates; replay_window is
sequence history; ordered_completion_buffer is allocated work retirement.
None supplied decoded IPv4 key ownership, unknown-until-last length, fragment
validation/overlap rejection and actual byte-payload publication together.

Fixed primary references, fetched read-only with HTTPS because web search and
web open both returned HTTP500:

* RFC791, https://www.rfc-editor.org/rfc/rfc791.txt , 94892 bytes,
  SHA256 6cfb387fcecfc1b72f2f69343c5b6951b5d263d708162e2b5c66ab8f394f6265.
  Offset8/MF/identification semantics only; this bounded policy is not its full
  reassembly algorithm or host requirements. In particular, rejecting every
  overlap and requiring explicit expiration are local service policies.
* lwIP STABLE-2_2_0_RELEASE src/core/ipv4/ip4_frag.c,
  https://raw.githubusercontent.com/lwip-tcpip/lwip/STABLE-2_2_0_RELEASE/src/core/ipv4/ip4_frag.c ,
  30302 bytes, SHA256 bb0ddf79430bcd073f7f837451f868107dd6ce60444df72b7c02aca7ca3d4ff6.
  Header has the complete BSD3-style license, Swedish Institute of Computer
  Science copyright2001–2004, with source/binary notice and nonendorsement
  conditions. Inspected limitations and overlap handling as implementation
  context only; this RTL has its own stated coverage/expiration policy.

Offline HDL closure, both original paths retained unchanged:

* ../../system/common_scaffold/memory/src/cip_sync_sp_ram.v : synchronous
  single-port byte-write/read-first RAM with response slot. clk_en tied1,
  reset inverted; writes' old-data responses discarded, replay responses held
  until ready. All addresses are range-checked before RAM access.
* ../../acceleration/operator_library/rtl/acc_ipv4_hdr_csum.v : example-only
  checksum atom. No global catalog or legacy source edits. The original source
  is already tracked; its first cumulative canonical reference is this batch.

files.f and example/files.f are evaluated from this package directory. No ROM,
generated coefficient, network library, external script or build generator is
required to use the delivered RTL. No historical qualification is inherited.

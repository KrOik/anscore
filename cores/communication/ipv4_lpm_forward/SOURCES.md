# Sources and semantic deduplication

Baseline98176a8f970354ebd6191d0370662ab35ff53664. New RTL, fixtures, TB,
independent numerical model and bounded runner are original Apache2 work;
the full repository Apache2 license is bundled. No external source was copied,
translated, imported or executed.

Read-only semantic search covered the whole cores tree, including older
untracked assets. ram_prefix_table supplies generic bit prefixes without packet
forwarding. ipv4_fragment_reassembly verifies an input header for payload
assembly but never performs route lookup or TTL transformation. ethernet_udp
is an endpoint parser/packetizer with fixed destination filtering. The toy
Toeplitz atom hashes32 bits and supplies no routing policy. No existing package
combined runtime LPM, validated TTL forwarding, rebuilt checksum and held
egress descriptor. No width-only clone is introduced.

Primary references were fetched from fixed official HTTPS URLs read-only after
web search returned HTTP500 (channel unsupported):

* RFC1812, https://www.rfc-editor.org/rfc/rfc1812.txt ,415740 bytes,
  SHA25672c2c27fecd3eef085f978a8c0ee5f364877708bfc0251af1c8437b56ad2f56d.
  Sections5.2.2,5.2.4 and5.3.1 supply header/longest-route/TTL context. The
  explicit exclusions in README mean this is not full RFC1812 conformance.
* FRRouting frr-10.2.1 lib/table.c,
  https://raw.githubusercontent.com/FRRouting/frr/frr-10.2.1/lib/table.c ,17080
  bytes, SHA2566a5ec157707b0ff50b223d32272d28c27c2378c96e0b0607b1d10fea18c2bd67.
  route_node_match records the most specific containing route in a software
  tree. Its header is SPDX GPL-2.0-or-later, copyright1998 Kunihiro Ishiguro;
  the fixed release COPYING was inspected (896 bytes,
  SHA2567bf053957d6c38e39a06a112c60ff35b228d3bd03edbe8c9a03508b051128d16).
  This is reference only. No FRR code/license-dependent implementation is
  included in this independent RTL; the unchanged local RAM scanner is used.
* A separate RFC1624 retrieval timed out. It was not used. This design performs
  complete checksum regeneration rather than implementing its incremental
  update algorithm. The failed retrieval record remains task-local.

Offline dependency closure (unchanged, repository Apache2):

* ../../storage/ram_prefix_table/rtl/ram_prefix_table.sv : full-domain32-bit
  runtime prefix service,40-bit values, synchronized read/check/mutation.
* ../../acceleration/operator_library/rtl/acc_ipv4_hdr_csum.v : authored
  four-word Internet checksum atom. Its CE is tied1 and reset inverted. Two
  real words and two zero words are supplied per transaction to keep its
  ordinary partial sum within18 bits; no legacy runner/model is imported.

Both source lists use those original canonical paths. No include, table ROM,
memory image, generated source, external software dependency or network access
is needed to compile the RTL. Historical checks do not qualify this new wrapper.

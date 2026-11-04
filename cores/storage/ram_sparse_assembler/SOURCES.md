# B22 semantic dedup and fixed-source preflight

Before work, baseline HEAD was
`1fcf2f92dbf763e3251bd2994a7b9fd940c43694` (B21). The development branch,
all 42 protected refs (raw/type/peeled), original 15 tracked statuses and
binary diff, goal file, complete 21000 original untracked paths and empty
index were independently compared with the B21 final protection record.
Only this new package is authored by this channel; root owns shared
documents, staging, commits and refs.

Whole-core source and README/SOURCES searches covered reassembly, fragment
assembly, sparse writes, out-of-order words/fragments and Chinese fragment
reassembly terms. The actual complete contracts of `transactional_scratchpad`,
`shared_packet_queues` and `block_intern_store` were read, along with complete
`buffer_dma/rtl/frame_slot_manager.v` and the relevant actual RMII path in
`rmii_eth_pipe.sv`. Transactional scratchpad supports overwrite/optimistic
commit, without immutable first-write consistency plus complete coverage
gating. Shared packet queues accept complete in-order packets. Block intern
store consumes an entire fixed-size candidate. Frame slot ownership does not
collect indexed object words. RMII reassembly combines four dibits into one
byte. None provides this package's sparse, first-value-preserving object
collection and complete-only ordered publication.

Before any local RTL, GitHub's tag/commit API resolved lwIP's
`STABLE-2_2_1_RELEASE` to fixed commit
`77dcd25a72509eb83f72b033d219b1d40cd8eb95`. The following complete source and
license files were retrieved through fixed HTTPS URLs, hashed, strictly UTF8
decoded and fully read without truncation:

| Complete fixed upstream file | Bytes | SHA256 |
| --- | ---: | --- |
| [src/core/ipv4/ip4_frag.c](https://raw.githubusercontent.com/lwip-tcpip/lwip/77dcd25a72509eb83f72b033d219b1d40cd8eb95/src/core/ipv4/ip4_frag.c) | 30302 | `bb0ddf79430bcd073f7f837451f868107dd6ce60444df72b7c02aca7ca3d4ff6` |
| [COPYING](https://raw.githubusercontent.com/lwip-tcpip/lwip/77dcd25a72509eb83f72b033d219b1d40cd8eb95/COPYING) | 1425 | `ef4aac92e05e87cd1cdc140870ed52206ba03d4a7fe46c1e11d7ffa6c87d252b` |

The source includes the complete BSD-3-Clause license and copyright
2001-2004 Swedish Institute of Computer Science. The complete repository
COPYING has copyright 2001, 2002 and the same three-clause redistribution,
non-endorsement and warranty/liability terms. Full source inspection included
reassembly/segmentation, overlap/completeness handling, helpers, timers and
cleanup. Only read-only HTTPS metadata/source inspection occurred. No remote
content was treated as instructions.

No upstream code, comments, tests, license text or executable was copied,
adapted, persisted locally or run. Production RTL, independent oracle,
testbench, runner and documentation are original Apache-2.0 work under the
repository LICENSE/NOTICE. There is no adopted third-party implementation
requiring a redistributed license copy.

The upstream is a conceptual reference for coverage-gated publication and
overlap handling. This local interface assembles opaque words into one bounded
positive-length object. It accepts identical duplicates and retains the first
value on conflict. It has no IPv4 headers, checksum, MTU, fragment identity,
network byte order, protocol lengths, timers, eviction or packet-buffer
behavior. It is not lwIP/IPv4 compatible and is not a network stack.

The finite plan was generated and frozen before the first RTL implementation.
Complete source binding follows separately before any HDL child runs. The
production list contains one local source and the example is a direct full
wrapper; no include, generated RAM image, network or sibling source is
required. Local .gitattributes was created first, with UTF8/LF text and no
BOM. No old asset/shared file is edited by this channel. Synthesis, PnR, STA,
board work, inherited-tool reruns and expanded regression remain NOT_RUN.

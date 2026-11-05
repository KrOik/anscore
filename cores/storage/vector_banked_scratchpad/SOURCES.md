# Source provenance and semantic preflight

Baseline: B27 release `8f8e49a2cb9c3e48ecfaecb811f2d313058979b8`.
Original package controller, wrapper, testbench, scalar reference, preparer,
runner, raw input recipes and documentation are Apache-2.0 repository work.
No external implementation was imported, translated or executed.

## Actual local reuse

The complete existing `cip_sync_sp_ram.v` was read before implementation and
copied byte-for-byte to `rtl/deps/cip_sync_sp_ram.v`:

| Field | Value |
|---|---|
| Original path | cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v |
| Bytes |2055|
| Raw SHA256 |04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619|
| Local modifications |None; original comments and source bytes retained|
| Additional production dependencies |None|

The source has shared `clk_en && valid && ready`, asynchronous active-low
control reset, unreset synchronous payload RAM, read-first OLD data in write
responses, byte write strobes, and one response slot. Every bank ties CE=1,
shares the core reset and uses full strobes. The new controller discards store
old data. It does not initialize memory on reset or claim unwritten zeros.
No old RTL/interface/evidence is modified or requalified. The included full
LICENSE is the exact 11560-byte root Apache-2.0 file, SHA256
`3ddf9be5c28fe27dad143a5dc76eea25222ad1dd68934a047064e56ed2fa40c5`.

## Actual semantic comparison before writing the new package

| Existing files/capability inspected | Why this package adds a distinct operation |
|---|---|
| common_scaffold/stream_bus/axi_multi_crossbar README and actual routing scope | Independent AXI transactions/targets; no masked vector, lane-ordered mixed aliases or aggregate vector response |
| storage/buffer_dma/rtl/mem_port_arbiter4.v | Four requesters serialize into one backend; no parallel banks or vector replay |
| storage/ram_read_gather README and RTL | Frame-owned external read deduplication with one outstanding read; no stores, local parallel banks or intervening write visibility |
| storage/atomic_scratchpad README and RTL | One serialized word RMW, not vector memory ownership |
| storage/transactional_scratchpad README | Optimistic context logs and commit validation, not lane-parallel memory service |
| common_scaffold/memory/src/cip_sync_sp_ram.v and cip_sync_tdp_ram.v | Appropriate reusable RAM primitives; no multi-lane conflict replay/aggregation |
| storage/ram_byte_write_coalescer and dma_2d_burst_plan README | Byte-store combination/address planning, not persistent banked vector RAM |
| storage/shared_packet_queues, ram_sg_range_map, word_memmove README | Packet ownership, physical span planning and overlap-safe copy have different contracts |
| acceleration/stream_block_transpose README and RTL | Actual fixed rectangular transpose already exists; plain transpose candidate was discarded |

Searches also covered actual system/storage/communication paths and broader
core filenames for transpose, banked/vector memory, scratchpad and capture
replay. The new controller is not a renamed crossbar/gather or a width variant.
All address arithmetic is runtime input driven; no sample lookup table supplies
the function. No old tests, matrices or shared checker were run.

## Read-only external preflight: partial, not PASS

The GitHub commit API was successfully read for PULP cluster_interconnect,
fixing commit `2967d8d17be0a6139229ca8d3d4956e182aec3de` and its tree
`7de25d5b5acd8296e5cbff54de2dc88f6694f8b1`.

The COMPLETE fixed-commit LICENSE was decoded from the GitHub contents API:

- URL: https://api.github.com/repos/pulp-platform/cluster_interconnect/contents/LICENSE?ref=2967d8d17be0a6139229ca8d3d4956e182aec3de
- Blob: `18e4f67692a9203423564bcd81b8c6c85140e747`
- Bytes:10329; SHA256:`6527a46225891b976fa94f634f6ee0cd22e1c7129d6f11c5c98c997627625fc7`
- License text: Solderpad Hardware License version0.51, including its explicit
  Apache-2.0 option. No upstream code is being redistributed by this package.

Actual fixed source/directory reads did NOT close. GitHub tree/root-content
requests encountered timeout/transport EOF; README.md contents returned404.
The final fixed tree request was supervised by an external 20-second process
deadline and stopped without a retry. Raw source/README retrieval and the
Linux v6.12 dev-kmsg ABI comparison also timed out. The general web tool
failed at its service interface before returning search results. An earlier
PowerShell HTTP helper outlived its requested internal timeout and ultimately
returned transport EOF; it was not treated as a successful source read.

Therefore external SOURCE_REVIEW is **INCOMPLETE**, not source/license PASS.
Only the commit metadata and complete LICENSE above were actually read. No
upstream architecture behavior, API compatibility or correctness conclusion
is inferred from those metadata. This package uses an original explicit
contract and the fully read, existing LOCAL RAM. It neither adopts nor depends
on the unread PULP implementation. No external scripts, installers, builds or
executables were run. No network call is part of preparation or HDL execution.

The source-writing authorization permits this independent/local-reuse route;
it does not authorize claiming the external source preflight has passed.

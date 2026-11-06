# Sources and semantic dedup

Baseline:98176a8f970354ebd6191d0370662ab35ff53664 (B43 parent). Original local
Apache-2.0 RTL. No external implementation was copied, compiled, imported or run.

Read-only `rg --files --hidden --no-ignore` over the **entire cores tree**, not
only168 snapshot packages, enumerated11590 RTL/Markdown files:9811 .v/.sv and1779
.md. Full-tree content searches included old untracked assets and archives.
Primary implementations were then read directly; archive/board copies were not
counted as new capabilities. Relevant existing overlaps and distinctions:

* acceleration/sorted_merge: two descending, paired nonempty sorted blocks;
  no runtime lower-bound promise, open silent feed, EOS independent of LAST,
  input monotonicity validation or keyed RAM heads. This package is an online
  ascending event-time service, with source completeness proof before release.
* acceleration/sorted_key_join: occurrence pairing/discard in paired sorted
  frames, rather than retaining every event in a total safe order.
* storage/ram_deadline_scheduler: exact unique-ID UPSERT/CANCEL/min/TAKE supplied
  cutoff. Actually reused unchanged. It cannot establish feed completeness or
  carry the whole wide event payload by itself.
* storage/ram_replay_window and utility_library/prod_sequence_window32:
  replay classification/stateless modular-range predicate, no payload release
  order or timestamp merge. Full64 nonmodular sequencing is retained here.
* communication/moldudp64_itch_rx: strict per-datagram sequence and normalized
  event decoding. A future packet rejects; no cross-feed chronological merge.
* communication/moldudp64_recovery_manager: missing-prefix request control,
  no stored future payload or event-time completeness policy.
* system/ordered_completion_buffer: submission order retirement, opaque metadata,
  no ordering by runtime event timestamp or lower-bound promises.
* storage/ram_sparse_assembler: complete finite immutable object COMMIT, no
  continuous multi-feed temporal order or independently advancing watermarks.
* storage/multi_venue_quote_state: latest absolute quotes with stale-source checks,
  not lossless all-event replay; itch_order_state/itch_l2_delta_book maintain
  order/book state rather than merge input histories.
* system/ip_test_shell loaded/capture replay, stream_bus_library capture_replay:
  host-loaded fixed stimuli in stored order, no event-time scheduling/safety.
* Existing credit/position risk ledgers and trade-correction OHLCV retain other
  financial state, without chronological multi-feed admission.

Fixed upstream comparison actually read on2026-11-06:

Repository https://github.com/apache/flink
Commit `7e28c6f6a95104ccc50487883bf5d0d0e91c2871` (resolved release-1.20 once).
File `flink-streaming-java/src/main/java/org/apache/flink/streaming/runtime/watermarkstatus/StatusWatermarkValve.java`
19319 bytes,SHA256 `3954e37023d08c227f4fd35853aac678f4770e86197b55e5853b0f7f3b572b7f`.
Full root LICENSE11357 bytes,SHA256
`c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`.
Both exact raw files at that commit were read in full via official GitHub raw
URLs. Web search returned HTTP500; official GitHub commit API/raw reads succeeded.

This Java source tracks per-input watermarks/statuses and propagates a minimum
using a heap, with signed long timestamps and active/idle policy. It is technical
reference only. This RTL independently uses exact unsigned64 timestamps, explicit
permanent EOS, conservative strict proof for empty sources, wide stored event
payloads and an existing serial RAM calendar. It never silently marks a source
idle or uses signed minimum/maximum values as timestamp sentinels. Java classes,
frameworks, software heaps and external runtime dependencies are not imported.

Actual production dependencies are listed in files.f and included in the
execution archive/hash closure. The shared RAM requires byte-multiple width,
clk_en=1 and reset polarity adaptation. No shared source is modified.

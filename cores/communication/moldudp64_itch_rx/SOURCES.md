# Source, license and semantic review

Baseline before implementation: `bbb761eb39c475ed52c7c42414a724e3f1ba6cae`.
All production RTL, oracle, runner, TB and example are independent original
ANSCORE code under Apache-2.0. No external source, dependency or build flow
is imported or executed. The local LICENSE contains the full license.

Before RTL, the following primary documents were retrieved/read from official
Nasdaq URLs on2026-11-06 (local date). Raw cache is ignored under .work/reference;
the public wire contract is independently recorded in README for offline use.
These PDFs are technical references, not software licensed for redistribution.

| Reference | SHA256 | Reviewed sections |
| --- | --- | --- |
|[MoldUDP64 v1.00](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/moldudp64.pdf)|96cdd02b8728a441cb970d1371a96e73c01e1edaffb2891d43667e2a0ad8add5|pages2–4: endian, session/header, implicit sequences, zero-length blocks, heartbeat/end|
|[TotalView ITCH5](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHspecification.pdf)|45e0531d1b4b3beb886e9618b2ab824a5aa9bda3a99c0dff03509306e68aacc3|page4 types/units; pages13–16 seven order formats and semantics|

Read-only implementation/license review also examined
[`bbalouki/itch`](https://github.com/bbalouki/itch) at immutable commit
`78b5f90bf5517a502793d693fb757a9f9f5e07c5`, specifically
[`itch/messages.py`](https://github.com/bbalouki/itch/blob/78b5f90bf5517a502793d693fb757a9f9f5e07c5/itch/messages.py)
(SHA256 b8fc2b8148c72c7f9c2ce6ced645383a5bbaf0ea44c1b44c205f686a003e3fb2)
and its complete
[`LICENSE`](https://github.com/bbalouki/itch/blob/78b5f90bf5517a502793d693fb757a9f9f5e07c5/LICENSE)
(MIT; copyright2025–2026 Bertin Balouki SIMYELI; SHA256
90126bffc8064ba8ad07862b5e9d18306b281cb436580560b6c60dd58e1bc47d).
The seven struct layouts cross-check official offsets. No Python from that
repository was imported/executed and no code was adapted. Official requests
succeeded via direct HTTP; the web search/open endpoint returned HTTP500.
A PDF text-display encoding error was corrected locally without changing or
executing external content; this was not an HDL/model qualification attempt.

Deep local review covered:

* `ethernet_udp`: whole Ethernet/IP/UDP validation and byte payload delivery,
  including KEEP0 empty packets. It does not interpret a financial payload or
  track implicit message sequences. That unchanged producer is compatible.
* `prod_stream_sequence32`: CE-qualified32-bit per-beat check with next=a+1
  even on mismatch. It cannot implement atomic64-bit packet count commits or
  strict no-update-on-gap/session semantics by simple port connection.
* `prod_sequence_window32`: a modular32-bit distance predicate without
  persistent session, block framing or payload ownership.
* `ram_replay_window`: independent64-bit sliding bitmap contexts, admitting
  late unseen numbers; it is an anti-replay classifier, not contiguous feed
  sequence ownership. No payload/parser capability is present there.
* `price_level_order_book`: aggregate price/quantity commands and depth reads,
  without order references, session, transport or exchange-message decoding.

Filename and specification/README searches across independent packages,
common_scaffold and operator/utility libraries found no MoldUDP/ITCH/FIX
handler. Generic packet routing/FIFO/image parser assets do not supply the
complete financial envelope+message+sequence behavior. Adding another field
extractor or width variant would not supply this capability; the new block
owns and rejects a complete packet before creating ordered events. None of
those mature assets is changed or copied into the closure.

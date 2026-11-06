# Provenance and offline closure

All new RTL/model/TBs/example/docs are original Apache-2.0 contributions. The
finite runner adapts this repository's B39 first-attempt/archive/timeout flow.
No external implementation was copied, translated, imported, installed or run.

Unchanged real dependencies:

- ../../system/common_scaffold/memory/src/cip_sync_sp_ram.v
  SHA256 04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619
- ../itch_l2_delta_book/rtl/itch_l2_delta_book.sv
  SHA256 9b3a640876c9a8cc21f5988110e27ebc5c260c5b8f13ad67928dd5eaf0c99d20

The core list contains one canonical RAM and the core. The actual example list
adds the existing L2 RTL once (instantiated twice) and the new wrapper. No other
runtime source, generated image, proprietary primitive or online lookup is
needed for offline use. Shared/old source files are untouched.

Read-only external specification inspected2026-11-06:
https://www.utpplan.com/DOC/UtpBinaryOutputSpec.pdf

Version printed September2026,61 pages,1311220 bytes, SHA256
68659d2f3ab4057adfad52cc20fb1c51c5b69481865d365014cec237a5399401.
Pages7/9/14/53 were inspected in memory: originating market centers, two-sided
participant quotes, National BBO appendages and quote wipe-out establish the
source/quote lifecycle context. Its wire-price, quote-condition, odd-lot,
protected-quote and regulatory semantics are broader than this normalized
unsigned32-price core. No UTP wire compatibility or full NBBO/SIP conformance
is claimed. Eligibility policy must be supplied before this service.

Read-only open source:
https://github.com/QuantConnect/Lean
Commit06eb5cb315c7265e00fd2c3c0eda1caef697e637 (master resolved to this immutable
commit before source reads), Apache License2.0, copyright2014 QuantConnect.

| Pinned file | Bytes | SHA256 |
| --- | ---: | --- |
| LICENSE | 10737 | 522cf0a716ce03f67d46f8fceb5bf78c5b84400ec5cd8d14bf9f02cddc1cb6ba |
| Common/Data/Consolidators/TickQuoteBarConsolidator.cs | 4953 | 10897e1dc4cf20b5b202557508141756bee32b2b395b6fa6b04dc7b943575824 |
| Common/Data/Market/QuoteBar.cs | 30242 | fd80a3ddeeb212ce5e7d64616044a32d7807bcba321380b61ac4344d9f6e56ec |

The complete consolidator and selected QuoteBar field/update sections were read.
It aggregates quote ticks into time/count OHLC quote bars and carries latest
sizes; it does not implement the persistent per-venue epoch, disabled-source,
strict sequence and same-price source-size service designed here. License was
identified as Apache2.0; no upstream source is part of the dependency closure.

Web search returned HTTP500 (unsupported alpha/search channel). Direct HTTPS
reads used in-memory buffers and pypdf text extraction; no external file or
cache was retained. Local wrong-path reads during inventory were corrected to
the actual stream_topk.v and existing operator inventory. No reference/network
event was a model or HDL execution.

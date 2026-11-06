# Provenance and offline dependency closure

The new RTL, ITCH composition, dictionary model, tests and documentation are
original ANSCORE Apache-2.0 work. The finite runner adapts the repository's own
B40 multi_venue_quote_state runner under the same license. No external code was
imported, translated, installed or executed. External inputs were read-only
technical comparisons and never treated as instructions.

Official Nasdaq TotalView-ITCH5.0 specification:
https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification.pdf
Read pages1,4,14,15,16,18 in memory. PDF36 pages/1200722bytes,
SHA25645e0531d1b4b3beb886e9618b2ab824a5aa9bda3a99c0dff03509306e68aacc3.
E references a retained display order and carries match/shares; C supplies
execution price and printable eligibility; broken trades affect statistics but
not the current book and cannot be reinstated. CORRECT is this generic core's
explicit extension, not an asserted ITCH5 message. Only normalized E/C from
actual order state are composed; non-displayed P/Q and B byte parsing are absent.
The generic core accepts all32-bit prices rather than enforcing exchange caps.

Read-only open-source comparison, fixed upstream:
https://github.com/QuantConnect/Lean/tree/06eb5cb315c7265e00fd2c3c0eda1caef697e637
Complete files read:

| File | Bytes | SHA256 |
| --- | ---: | --- |
|LICENSE (Apache-2.0)|10737|522cf0a716ce03f67d46f8fceb5bf78c5b84400ec5cd8d14bf9f02cddc1cb6ba|
|Common/Data/Consolidators/TickConsolidator.cs|4526|b435c5bceb7916027fec55a4ac5644b103622f6e17a92b660950c8c4631ed74c|
|Common/Data/Consolidators/TradeBarConsolidator.cs|5269|f9cb755a4fecdd489d87f8e8d01c23637b85b3c6643f5befa524c5fc142797fd|

These accumulate forward OHLCV into time/count bars and have no retained match
lookup/break/correction. No source was copied. Web-search transport returned
HTTP500; direct fixed official HTTPS succeeded. One unavailable guessed filename
and transient EOF preceded the complete successful reads. The first PDF text
output hit terminal encoding; a complete targeted UTF-8 reread succeeded. No
download/cache persisted and no upstream software was imported or run.

Unchanged baseline31a83135a22f845d85840524986895217567625c dependencies:

- ../../system/common_scaffold/memory/src/cip_sync_sp_ram.v
- ../ram_hash_table/rtl/ram_hash_table.sv
- ../itch_order_state/rtl/itch_order_state.sv

files.f and example/files.f list every RTL source explicitly, relative to this
package root. No includes, initialization files, third-party runtime, generator,
vendor primitive or network dependency. Exact dependency/source/tool hashes are
part of FINITE_PLAN.json and copied before any reference-model call.

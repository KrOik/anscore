# Sources, de-duplication and offline dependency closure

All new production RTL, testbench and model are original ANSCORE work under the
local full Apache-2.0 LICENSE. No external source was copied/adapted, imported,
compiled or executed. No network is needed to build the delivered package.

Before implementation, a fixed external C++ reference was read only:
[Kautenja/limit-order-book](https://github.com/Kautenja/limit-order-book), commit
`7fc059daf10f0d14d3cae79fc6c7505c956307ac`:

| File | SHA256 | Inspection |
| --- | --- | --- |
|[include/limit_order_book.hpp](https://github.com/Kautenja/limit-order-book/blob/7fc059daf10f0d14d3cae79fc6c7505c956307ac/include/limit_order_book.hpp)|380fadeb216e4e79bbaa8f0b2964aba2b1eb842ba0f23cc79ef34f5a80c53f7f|Per-price volume and best-price/best-volume access; reduction and cancellation|
|[LICENSE](https://github.com/Kautenja/limit-order-book/blob/7fc059daf10f0d14d3cae79fc6c7505c956307ac/LICENSE)|f9d7389616b3f7e7050d5453427e7977d679d7d7832f5b572ed845aee923c57a|Complete MIT text, copyright2019 Christian Kauten|

That reference automatically matches crossing limits and uses zero as empty best
price; neither behavior is used here. This passive feed-reconstruction service
retains crosses and has explicit validity for legal price zero. The external
implementation is algorithm/context reference only. Wire lifecycle semantics
remain in unchanged B36, whose SOURCES.md pins the Nasdaq specification and its
own fixed read-only parser reference. B37 consumes its documented compound deltas.

Actual source-level semantic de-duplication covered price_level_order_book,
price_level_ioc_matcher, ram_ordered_dictionary, ram_hash_table and itch_order_state,
plus common_scaffold and operator_library searches. Existing book supplies atomic
single-price arithmetic,32-bit totals and ranked depth; B37 supplies paired
preflight/commit and38-bit totals for64 combined levels with post-state BBO.
See ARCHITECTURE.md for the capacity/interface reasons not to widen/fork it.

Canonical unchanged dependencies, included once in each applicable file list:

| Repository path | SHA256 | Role |
| --- | --- | --- |
|cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v|04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619|Production72-bit RAM; private clk_en tied1, response ownership/read-first preserved|
|cores/storage/itch_order_state/rtl/itch_order_state.sv|e17ff36cf69eee9d9cfecd628f0ac5ba9d6aac0136853f130f3dc5ece8165fb0|Actual example only; normalized ITCH live-order lifecycle|
|cores/storage/ram_hash_table/rtl/ram_hash_table.sv|e0ab208b436dd3e5d11b8f5a7820d555338e58c22849ad3ca8441b8434105821|Two instances inside unchanged example order state|

No dependency is relocated or duplicated. These references use the exact B36
snapshot canonical paths/bytes. Existing old-source licenses remain in their
packages. Historical dependency simulation evidence is not a B37 combination
PASS. The B37 first run archived/hashed the exact canonical bytes before model/
tool invocation, and its actual combination passed the listed finite checks.
The unchanged source copies and raw evidence are retained with that receipt.

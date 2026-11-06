# B36 semantic and source review

Current development baseline is B35 feature
`b56ae2d9735d4026fcf8340119967d3cc6deac40` plus closeout `8ba6835f`.
All wrapper, model, tests, example and prose are original Apache-2.0 work.
No external implementation/build flow was imported or executed.

Before RTL, official
[Nasdaq TotalView ITCH5 specification](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHspecification.pdf)
was fetched and read again on2026-11-06. SHA256:
`45e0531d1b4b3beb886e9618b2ab824a5aa9bda3a99c0dff03509306e68aacc3`.
Page4 defines unsigned wire fields/decimal prices; pages13–16 specify Add,
cumulative Modify/deletion, C printable/execution price, and U inheritance of
side/symbol with new reference and total quantity. This independent state
contract retains L2-relevant fields rather than claiming full MPID/audit state.
The PDF is referenced, not redistributed as licensed software.

Fixed read-only reference/license inspection also fetched
[`bbalouki/itch`](https://github.com/bbalouki/itch) commit
`78b5f90bf5517a502793d693fb757a9f9f5e07c5`, specifically
[`itch/messages.py`](https://github.com/bbalouki/itch/blob/78b5f90bf5517a502793d693fb757a9f9f5e07c5/itch/messages.py)
(SHA256 `b8fc2b8148c72c7f9c2ce6ced645383a5bbaf0ea44c1b44c205f686a003e3fb2`)
and complete
[`LICENSE`](https://github.com/bbalouki/itch/blob/78b5f90bf5517a502793d693fb757a9f9f5e07c5/LICENSE)
(MIT; copyright2025–2026 Bertin Balouki SIMYELI; SHA256
`90126bffc8064ba8ad07862b5e9d18306b281cb436580560b6c60dd58e1bc47d`).
Modify/Replace descriptions and struct fields were reviewed before design.
No external Python was imported/executed; ignored .work/reference retains
these temporary reads for orchestrator cleanup. No copied source needs an
additional third-party redistribution license. The full Apache-2.0 text is local.

Deep de-duplication read actual RTL/specification boundaries of the following:

| Asset | Actual capability and boundary |
| --- | --- |
|ram_hash_table|KEY/VALUE1..64, exact mutable GET/PUT/DELETE/CLEAR; no event lifecycle, side inheritance, cut underflow, global side uniqueness or compound rename|
|ram_ordered_dictionary|K/V1..32, sorted lookup/range; cannot represent full64-bit order IDs without mature-source changes|
|price_level_order_book|Aggregated price/quantity only; no per-order references, exact-price GET or quantity width above32|
|price_level_ioc_matcher|Consumes aggregate opposite-side liquidity; no passive ITCH order reconstruction|
|moldudp64_itch_rx|Validates/parses and sequences datagrams; intentionally does not retain live order records|
|utility sequence/replay operators|Per-number classification; no mutable order map or lifecycle|

There was no equivalent order-ID state engine in independent IP,
common_scaffold or operator libraries. A65-bit side/price32/qty32 record does
not fit the mature hash's64-bit value contract. Two unchanged side tables
preserve all wire bits and avoid a width-only fork. The independent increment
is checked persistent lifecycle plus externally atomic rename/deltas, not
another dictionary interface. Aggregating64 maximal32-bit quantities can
need38 bits, so directly claiming a complete loop through the old32-bit L2
book would be incorrect. No such mature source was modified.

Canonical dependencies, each compiled once:

| File | SHA256 | Role |
| --- | --- | --- |
|../ram_hash_table/rtl/ram_hash_table.sv|e0ab208b436dd3e5d11b8f5a7820d555338e58c22849ad3ca8441b8434105821|Two instances in production; source appears once|
|../../communication/moldudp64_itch_rx/rtl/moldudp64_itch_rx.sv|d5ac572f9c0362a27c647aca96f7c189716eacbae2a7f5279fea448ec70ebd04|Actual composition example only|

The hash's current bytes match verification.json and its22 historical finite
PASS checks, including256/KEY64/VALUE64/TAG32. Those are dependency evidence,
not a new combination PASS. B35's receiver has its own checked delivery.
All remain HW_UNVERIFIED; the B36 finite runner archives the exact canonical
bytes it actually uses before executing any model/tool.

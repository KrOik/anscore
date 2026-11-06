# Provenance and semantic deduplication

All new RTL, controller, mathematical oracle, preparation, TB and runner code is
original ANSCORE Apache-2.0 work. No external source was copied, translated or
executed. The local LICENSE is the repository Apache-2.0 license.

The production composition references these **unchanged** canonical sources:

- cores/storage/price_level_order_book/rtl/price_level_order_book.sv
- cores/storage/ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv
- cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v

Baseline is09de72c578b3099d4e867c739118faa7607f663d. Exact dependency bytes are
recorded in SOURCE_SEAL.json, not copied into an alternate production tree.
Their historical verification is not upgraded by this new candidate.

Before authoring, the entire repository including hidden/unindexed assets,
experiments and retained reports was searched for auction/uncross/clearing-price,
集合竞价 and 最大可成交 across RTL, Python, README and JSON. No equivalent engine
was found. The only auction references were explicit exclusions in
multi_venue_quote_state's B40 delivery/qualification metadata. Direct review of
the related package boundaries found:

- price_level_order_book: atomic quantities and ranked depth, with crossed books
  retained exactly and no matching; reused as the actual persistent backend.
- price_level_ioc_matcher: continuous taker consumption with per-price fills;
  does not determine a uniform max-volume clearing price across both curves.
- multi_venue_quote_state: BBO consolidation and source eligibility; explicitly
  excludes auction/sale-condition eligibility and retains locked/crossed books.
- itch_order_state/itch_l2_delta_book, trade_correction_ohlcv_state,
  position_limit_reservations and pretrade_credit_ledger: order state, execution
  statistics or credit/position admission; none computes uniform-price auction
  curves or clearing-price ties. Generic ordered dictionaries/trees expose
  storage queries, not this two-sided price-selection policy.

The independent increment is whole-snapshot demand/supply evaluation, aggressive
limit-order eligibility, exact matched/imbalance output and deterministic
multi-criterion clearing-price choice, plus a non-torn actual-book read service.

Read-only external inspection before local RTL authoring:

- https://github.com/arielb57/auctionclear at fixed commit
  a929b3633411ce1430a25a5f67753c75d8e7519c.
- src/book.rs: complete source inspected for aggregate demand/supply at a price,
  positive-volume outcomes, through-limit eligibility and separation from fills.
- src/policy.rs: complete source inspected for explicit policy chains and
  differences among venue interpretations. The local policy is its own stated
  limit-only contract; no venue compliance or allocation behavior is imported.
- LICENSE: MIT, copyright2026 Ariel Belhamou, inspected before authoring. No
  upstream code or dependency was incorporated, so no upstream build/runtime
  is required. Raw source/license hashes and exact URLs are in
  EXTERNAL_SOURCE_REVIEW.json.

GitHub API and fixed raw HTTPS files were read as untrusted reference data.
The unavailable search endpoint was bypassed with read-only GitHub API queries;
no installer, upstream script, cargo build or remote instruction was executed.

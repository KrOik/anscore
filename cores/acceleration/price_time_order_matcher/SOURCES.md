# Semantic and provenance preflight

Baseline: 05b9614c3962e9d4ae934c4b9c7bd315cc01aed4. Source-only inspection,
2026-11-07 Asia/Shanghai; no project import, AST, model, HDL or Git command ran.

Actual existing behavior was read, not inferred from names:

* price_level_order_book stores aggregated quantities and explicitly allows
  crossed books without trading; no individual IDs or same-price FIFO exists.
* price_level_ioc_matcher consumes a level per fill and cancels the taker
  remainder; no maker ID, time priority or resting incoming order exists.
* itch_order_state applies externally supplied executions/cancels/replaces to
  retained IDs. It never selects a counterparty or creates an execution.
* itch_l2_delta_book aggregates those deltas and reports BBO without trading.
* order_risk_reservation tracks pending-new/live/pending-cancel quantity risk;
  it does not compare prices, create trades or implement an order book.
* call_auction_clear computes an aggregate uniform-price indication, without
  per-order allocation, time priority or book mutation.

Those services cannot obtain this behavior from a port/width wrapper. This
new original controller composes two unchanged, behavior-matched dependencies:

| Canonical source | SHA256 | Provenance/license |
|---|---|---|
| cores/storage/ram_hash_table/rtl/ram_hash_table.sv | e0ab208b436dd3e5d11b8f5a7820d555338e58c22849ad3ca8441b8434105821 | Original workspace RTL; root Apache-2.0/NOTICE |
| cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v | 04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619 | Original workspace RTL; root Apache-2.0/NOTICE |

DEPENDENCY_PROOFS.json establishes actual baseline inclusion, rather than
inferring it from a current workspace file. The retained B48 final tree capture
contains37021 paths and has SHA256
3d4898586c2e917f8c29c12d00afdfc050fe4dae9847183123a8cc8683c30ad9.
Both sources are mode100644/blob. Their raw Git blob SHA1 values are
559251bb3b941381865ac06c3c1ebfdb7c153efd (hash table) and
1668735305bf45d22beef23aadeb4d58552a6171 (RAM), recomputed from current raw
bytes and compared with that tree. No new support bridge is admitted.

Public primary behavioral reference:
[Coinbase Exchange matching engine](https://docs.cdp.coinbase.com/exchange/concepts/matching-engine),
HTTP200 read-only on the preflight date, describes price-time processing. Its
self-trade-prevention and venue order semantics are not implemented here; this
is a deliberately smaller independent policy, not a Coinbase protocol clone.

Read-only open-source discovery used GitHub's repository search filtered to
MIT. Before reading its README, the complete MIT license for
[brprojects/Limit-Order-Book](https://github.com/brprojects/Limit-Order-Book)
was read through the GitHub API: copyright2024 Benjamin Rienecker, license blob
85bda1c438d486b3f28c72b217b2ac68f3e025b5. Its fixed main commit was
af6e5349874649fe196bd6c26653d357f5a751f2; README blob
6d58e7d537ef50906e1e816fe9641cac5f52c8f9 was read for its price/FIFO overview
and broader software feature boundary. No implementation files were downloaded,
copied, translated or executed. Its C++ tree/linked-list implementation and
published software speed are not evidence about this RTL. No external source
is redistributed or required by the offline closure.

All new RTL/example/oracle/TB/runner/docs are original Apache-2.0 contributions
under the copied root LICENSE. No mature dependency is edited. Current physical
properties remain HW_UNVERIFIED; source claims do not qualify hardware.

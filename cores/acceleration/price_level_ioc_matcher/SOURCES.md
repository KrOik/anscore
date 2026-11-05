# Provenance and semantic deduplication

The controller, example, Python sorted-dictionary oracle, finite runner and TBs
are independently authored ANSCORE Apache-2.0. The repository Apache license is
included. No upstream implementation was copied or executed.

Before authoring, repository RTL, README and catalog contents were searched for
matching engines, IOC/taker execution, order-book sweep and price-level mutation.
The B33 `price_level_order_book` explicitly excludes matching; it supplies the
unchanged storage service reused here. `ram_ordered_dictionary` supplies ordered
key/value operations but no two-sided taker transaction. Graph/bipartite matching
solves assignment and has no market-liquidity semantics. No existing package
provided this opposite-side BEST/limit/SUB/fill/completion capability. This is
an actual composed execution operation over persistent two-sided liquidity.

Canonical reused source hashes at baseline
`bbb761eb39c475ed52c7c42414a724e3f1ba6cae`:

- `../../storage/price_level_order_book/rtl/price_level_order_book.sv`:
  `d69f03641c7928bf70fc28b44c59c4a892c62c3942d702deb11b4ac5d463d72e`.
- `../../storage/ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv`:
  `03b9bd7147fb0d0275df0f445aa7ee0895f2ee74d0cb38e57ba20ebce970aa91`.
- `../../system/common_scaffold/memory/src/cip_sync_sp_ram.v`:
  `04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619`.

Before local implementation, read-only official GitHub source/API inspection
reviewed [exchange-core](https://github.com/exchange-core/exchange-core) at
commit `2f8548749839e9095c8dc597e4b61521d259fa5d`, specifically
[`OrderBookNaiveImpl.java`](https://github.com/exchange-core/exchange-core/blob/2f8548749839e9095c8dc597e4b61521d259fa5d/src/main/java/exchange/core2/core/orderbook/OrderBookNaiveImpl.java)
(`case IOC`, `newOrderMatchIoc`, `tryMatchInstantly`, rejected remainder) and
the actual root [`LICENSE.txt`](https://github.com/exchange-core/exchange-core/blob/2f8548749839e9095c8dc597e4b61521d259fa5d/LICENSE.txt), Apache-2.0.
A first guessed `/LICENSE` path returned404; repository contents identified
the actual file before implementation. This is behavior reference only. The
original L2 controller does not implement that project's individual-order book,
matching-event objects or exchange feature set. No unknown build, installer,
script or instruction from upstream was run. Dependencies and tests remain
fully usable offline.

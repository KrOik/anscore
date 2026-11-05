# Persistent price-level order book

This market-data building block maintains bounded bid and ask price levels and
their aggregated quantities. It adds checked atomic SET/ADD/SUB/DELETE, best
bid/ask and ranked depth queries to two **unchanged** ordered RAM dictionaries.
No individual order IDs, matching, exchange protocol, floating-point prices,
timestamps, feed sequence recovery or host-prepared sorting are required.

The independent functional increment is the market-side ordering and a single
command owner across lookup, quantity arithmetic and mutation. Generic
dictionary access alone cannot provide this atomic quantity service. Bid keys
are bitwise-complemented so dictionary ascending order is highest-price first;
ask keys are unchanged. Quantity-zero levels are never stored.

## Parameters and numerical domain

`LEVELS=1..32` is capacity **per side** (default16). `PRICE_W=1..32` and
`QTY_W=1..32` default32; `TAG_W=1..32` defaults8. Unsupported values reference a
named missing module. Prices and quantities are exact unsigned integers with
no sentinel: price0 and the maximum price are ordinary levels. The application
chooses price-tick and quantity-lot units; no scale conversion, signed prices,
rounding or saturation is performed. ADD uses QTY_W+1 bits and rejects overflow
without modifying the book. SUB rejects insufficient quantity without wrapping.

## Interface and operations

All activity uses rising-edge `clk`. `rst_n` is asynchronous active-low and is
shared by both reused dictionaries/RAMs. Assertion immediately masks public
ready/valid, cancels in-flight commands and held responses, and empties both
sides, including previously committed levels. RAM contents are not reset and
cannot become visible after logical occupancy clears. Release reset
synchronously to clk; no reset synchronizer is included. There is no CE, CDC,
runtime configuration, packet/frame marker, memory-mapped bus or external RAM
port. Do not connect a CE-qualified stream without an explicit adapter.

A command transfers on `c_valid && c_ready`; a response transfers on
`r_valid && r_ready`. One command owns the complete book through response
retirement. There is no same-edge retirement/admission fallthrough. Every source
holds valid and all its fields while blocked. All response fields, including
both side counts, remain stable under arbitrary output backpressure. A stalled
response does not postpone a mutation: all private changes are complete before
its first valid. Reset is cancellation, not transaction rollback.

Command fields are `c_op[3:0]`, `c_side` (0 bid,1 ask), `c_price[PRICE_W-1:0]`,
`c_quantity[QTY_W-1:0]`, `c_rank[31:0]` and opaque `c_tag[TAG_W-1:0]`.

| Op | Meaning | Input fields used |
| --- | --- | --- |
|0 SET|Install/replace a positive absolute quantity|side,price,quantity|
|1 ADD|Add a positive quantity; create an absent level|side,price,quantity|
|2 SUB|Subtract a positive quantity; exact subtraction to0 deletes the level|side,price,quantity|
|3 DELETE|Remove an existing complete price level|side,price|
|4 BEST|Return highest bid or lowest ask|side|
|5 DEPTH|Return zero-based rank in that side's best-to-worst order|side,rank|
|6 CLEAR_SIDE|Empty just the selected side|side|
|7 CLEAR_ALL|Empty both sides under one command owner|none|
|8..15|BAD_OP, no mutation|none|

SET/ADD/SUB with quantity0 return BAD_QUANTITY; zero does not mean delete.
DELETE ignores quantity. Existing SET/ADD replacements are allowed while full;
an insertion beyond the selected side's capacity returns FULL. The two sides
have independent capacity. A crossed or locked book is retained exactly; no
trade or matching is triggered. The caller must explicitly subtract/replace
quantities according to the chosen market feed's semantics.

Responses echo `r_op`, `r_side` and `r_tag` for every command, including
CLEAR_ALL (its ignored side is still echoed). `r_status[2:0]` is0 OK,
1 NOT_FOUND,2 FULL,3 BAD_QUANTITY,4 OVERFLOW,5 UNDERFLOW,6 BAD_RANK,7 BAD_OP.
For DEPTH, the complete32-bit rank is checked before narrowing: rank>=LEVELS
returns BAD_RANK; a legal rank beyond current occupancy returns NOT_FOUND.
Empty BEST and missing SUB/DELETE return NOT_FOUND.

For a successful mutation, `r_price` is its price, `r_quantity` the installed
quantity (0 after deletion), `r_previous` the prior quantity (0 on insertion),
and `r_found` reports whether the level existed before the operation. Successful
BEST/DEPTH return its price/quantity with found=1 and previous=0. Successful
clears and every error return found/price/quantity/previous all0. `r_bid_levels`
and `r_ask_levels` are32-bit occupancy counts **after** the command, including
errors. Payloads have no snapshot meaning when r_valid=0.

## Reuse, schedule and architecture

Each side is one existing `ram_ordered_dictionary` with exact source reference;
both reuse canonical `cip_sync_sp_ram`. Their CE-qualified internal memory
interfaces are already enclosed by the dictionary and tied enabled. The new
wrapper does not alter shared interfaces or implement another tree/CAM.
Lookup and update retain one top-level command owner, so no observer can see
an intermediate GET-to-PUT/DELETE state. CLEAR_ALL privately clears bid then
ask before releasing one response.

BEST uses ordered SEEK_GE(0). DEPTH privately streams RANGE rows in best-price
order, captures the requested rank and drains the END token before responding.
It returns a single depth level, not an externally streamed snapshot. Dictionary
binary search is logarithmic, insertion/deletion shifts at most LEVELS rows,
and DEPTH scans at most LEVELS rows. Consequently command latency varies with
occupancy, position and operation; it is O(LEVELS) in the worst case. Commands
are serialized and there is no one-update-per-clock throughput claim. First
response latency is independent of the output sink; unlimited sink stalls
remove any whole-transaction completion deadline.

Logical row RAM storage is `2*LEVELS*8*ceil((PRICE_W+QTY_W)/8)` bits:2048bits at
defaults,4096bits at the maximum width/capacity. Additional dictionary and wrapper
control registers hold search indices, one row, command fields and responses.
The default capacities are deliberately small. Qualitative resource risk is
**LOW** for storage volume, **MEDIUM** for target RAM packing and update latency;
source structure does not prove device-fit, actual BRAM usage, timing, power
or market-data line-rate performance. No multiplier, divider, vendor primitive
or external memory is added by the wrapper.

Both `files.f` and `example/files.f` resolve from this package root. Complete
production closure is the wrapper, unchanged sibling dictionary and canonical
RAM listed there. `example/market_depth16.sv` exposes every default-profile port.
Use BEST/DEPTH responses as inputs to a separately designed spread/risk engine;
the user remains responsible for feed normalization and tick/lot definitions.

## Finite validation

Run `python cores/storage/price_level_order_book/run_tests.py` from the
repository root. The runner uses absolute OSS-suite paths, freezes exact input
copies and independently prepared vectors **before** tool execution, and
records source/dependency/tool/vector/raw SHA-256 hashes. Every compiler/vvp
child has a20-second watchdog with process-tree termination and bounded cleanup.
Missing tools, failures and timeouts stop subsequent child launches. A PASS
requires the complete selected plan, unchanged inputs, successful exits and
the TB completion marker. There is no automatic retry. Optional `--profile`
selects a fixed profile for a targeted follow-up without widening coverage.

The independent Python reference uses two plain dictionaries and sorted price
lists; it does not use complement keys, ordered RAM, binary search or RTL states.
The TB checks every command/response field, quantities/counts after errors,
both side rankings, full replacement/capacity failures, high-bit/all-one prices
and quantities, overflow/underflow, best-level deletion, crossed books, input
gaps, held responses with a blocked next command and reset in idle/active/held
ownership. Actual executed status is in `QUALIFICATION.md`; unexecuted tests
are not PASS. All new work remains HW_UNVERIFIED. Provenance is in `SOURCES.md`.

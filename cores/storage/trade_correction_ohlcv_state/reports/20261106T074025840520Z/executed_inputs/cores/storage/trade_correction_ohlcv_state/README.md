# Correctable retained-trade OHLCV state

`trade_correction_ohlcv_state` retains complete match identifiers and recomputes
per-symbol OHLCV after additions, trade breaks and price/quantity corrections.
Removing an old extreme or first/last trade reveals the remaining active record;
this cannot be recovered from a forward-only OHLC accumulator. The exact VWAP
numerator and denominator are returned, with no division or rounding.

Initial maturity: RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED. The
eventual finite receipt determines source-check maturity. No synthesis, PnR,
STA, board, PPA or inherited regression is authorized.

## Domain and retained history

ENTRIES defaults to32 and supports1..64, including non-powers of two. TAG_W is
1..32, default8. Unsupported parameters elaborate a named missing module.
Symbols are arbitrary unsigned32 keys; match IDs and audit sequence keys are
full unsigned64. All bit patterns are legal. Prices/quantities are unsigned32;
price0 is legal and an ADD/CORRECT quantity must be positive. There is no implicit
price scale or exchange price-ceiling check. Volume38 and notional70 exactly
cover64 maximum unsigned32 quantities/products, with no saturation or wrap.

Open/close select the smallest/largest `(sequence,match)` unsigned lexicographic
key. Equal sequences therefore use the complete match ID as a deterministic tie
break. Sequence is an ordering key, not a monotonic admission check, timestamp,
modular sequence number or freshness timer. CORRECT keeps the original symbol,
match and sequence, replacing the entire price and positive quantity.

BUST changes active to broken and keeps its allocated row and identity. A broken
ID cannot be added again or corrected before CLEAR; repeated BUST returns BROKEN.
Broken rows consume capacity. This is bounded retained history, not an unlimited
full-day tape or rolling time window. CLEAR is the explicit new history epoch.

## Transfers, operations and results

One clock, synchronous active-high `rst`, no CE/CDC. Transfers occur at rising
edges with valid and ready. Hold all source fields while blocked. One command
owns the service through its response retirement; no same-edge next admission.
Results remain stable under arbitrary backpressure. Reset masks ready/valid/busy,
cancels work and held results, clears metadata/fault and leaves RAM unreset.
Previously written payload cannot become visible without a fresh allocation.
Private RAM uses `rst_n=!rst`, CE1 and ordinary request/response handshakes.

| Op | Command | Used fields |
| ---: | --- | --- |
|0|ADD|symbol,match,sequence,price,quantity,tag|
|1|BUST|match,tag|
|2|CORRECT|match,price,quantity,tag|
|3|GET|match,tag|
|4|QUERY|symbol,tag|
|5|CLEAR|tag|
|6|INVALIDATE|tag|
|7..15|BAD_OP|op,tag|

Status values are0 OK,1 BAD_QUANTITY,2 DUPLICATE,3 FULL,4 NOT_FOUND,5 BROKEN,
6 INVALID_STATE,7 BAD_OP and8 BACKEND_FAULT. Priority is undefined op, CLEAR,
INVALIDATE, faulted, ADD/CORRECT zero quantity, then full identity lookup. ADD
checks duplicate before capacity, including full tables and broken IDs. GET
returns active or broken records. BUST/CORRECT check missing before broken.
QUERY on an absent symbol succeeds with an empty summary. Expected rejections
preserve all records and metadata; they do not poison the epoch.

Every result echoes op/tag. `r_entries` is the global allocated count even on
errors. A successful ADD/BUST/CORRECT/GET has `r_trade_valid=1` and the retained
post-command record; BUST/GET may report active0. Successful ADD/BUST/CORRECT/QUERY
has `r_stats_valid=1` and the complete post-command active summary for `r_symbol`.
`r_count` is active trade count; volume is sum(quantity), notional is exact
sum(price*quantity). An empty summary has count/volume/notional/OHLC0. Fields
without their valid flag are canonical zero, except `r_symbol` identifies a
successful GET or summary. CLEAR/INVALIDATE and errors have all record/summary
fields0. `faulted` is a level output and is held with the response.

INVALIDATE preserves history and blocks normal operations until CLEAR/reset.
Unexpected RAM errors, duplicate internal identities or allocated quantity0
return BACKEND_FAULT and set faulted. All allocated rows read are checked for
positive quantity, including broken or other-symbol rows. No backend rollback,
timeout, persistent journal or automatic repair is provided. Ordinary mutations
are fully prechecked before the sole row write/metadata commit.

## Real ITCH combination

`example/itch_execution_statistics8.sv` instantiates the unchanged8-order
`itch_order_state` (two actual hash tables) and8-entry trade state. It accepts
normalized A/F/E/C/X/D/U events. Both are owned until one public result retires.
An actual successful E uses the old retained display price and executed shares;
a printable C uses its explicit execution price. Non-printable C still removes
shares from the book and does not create a trade statistic. Match and sequence
come from the original event. This example receives normalized fields, not UDP
bytes, and does not add P/Q/B decoding to the existing receiver.

Management op0 CONFIG clears trade history then configures/clears actual orders
using locate/stock;1 CLEAR clears both and retains order selection;2 GET_TRADE,
3 QUERY_STATS,4 BUST and5 CORRECT act only on trade history;6 QUERY_ORDER uses
`c_order`;7 INVALIDATE invalidates both;8..15 is BAD_OP. The example maps the
configured locate to a zero-extended symbol32. Only CONFIG updates that mapping.
Trade management never resurrects or modifies resting orders. Before order
configuration, ops2..6 return wrapper status1 without a child operation.

`r_wrapper_status` is0 ordinary,1 NOT_CONFIGURED,2 BAD_OP,3 ISOLATION_FAILED.
`r_order_status` and `r_trade_status` are independent child statuses; zero in an
untouched child field does not certify that child ran. `r_old/new_*`, removed and
order_count reflect actual book results. The trade record/summary fields are
populated only by an ordinary completed trade child command. `r_admin/op/tag`,
request_order and event_sequence identify the accepted public request.

If an actual order event poisons the order state, or a printable execution has
already changed the book and its statistics ADD fails, the wrapper issues and
retires INVALIDATE to both children before publishing completion. The original
failed child status is preserved. `r_isolated` acknowledges both invalidations;
their independent statuses are `r_isolation_trade_status/order_status`. Explicit
management INVALIDATE also acknowledges both through r_isolated. Prior order
mutations are retained and no rollback is claimed. CONFIG/CLEAR starts a new
empty common epoch. Reset cancels both children together, including their hash
initialization sweep. Different-locate ignored events remain retirable.

## Budget and finite qualification

One224-bit synchronous RAM row per retained ID, plus allocated/active bitmaps:
7168 payload+64 metadata bits default;14336+128 maximum. One shared32x32 multiplier
register feeds a70-bit accumulator. Query aggregation takes three clocks/row;
identity search takes two. Source first-valid bounds are0 immediate,2N+1 GET or
lookup rejection,3N+1 QUERY,5N+2 BUST and5N+4 ADD/CORRECT. The finite TB allows
5N+8 (168 default/328 maximum). Earliest transfer adds one edge; stalls extend
ownership without a bound. These are RTL-cycle budgets, not hardware throughput.

Core files.f requires only the shared RAM and new RTL. Example/files.f explicitly
adds unchanged order state and hash RTL; no nested file lists, includes, ROMs,
vendor primitives, external generators or online services. Compile from this
package root. ARCHITECTURE.md records semantic comparisons and tradeoffs.

The frozen finite plan has three syntax checks and four compile/sim pairs:
N1/T1,N7/T8,N64/T32, and the actual ITCH example. The dictionary oracle is imported
only after exact source/tool/plan archiving. All three vector files are saved and
hashed before HDL. Every checked command is followed by an actually admitted
future QUERY and both responses are held six clocks. Five core and five example
reset cuts include committed order state before trade completion, RAM responses,
write-before-metadata-commit and held results. Each child has20s hard limit,
tree termination5s/drain2s. First failure stops; no automatic retry/repair or
successful-profile rerun. Raw evidence and compiled images remain retained.

# B41 semantic selection and architecture

Baseline31a83135a22f845d85840524986895217567625c. This adds retained trade identity
and nonmonotonic statistics repair. It is not a new width or a renamed ordered
map. Full-row identity lookup and recomputation recover OHLC extremes and first/
last records after BUST/CORRECT; a prior aggregate alone cannot do so.

Actual-source comparisons: `itch_order_state` retains open orders and emits
removal deltas, explicitly discarding match/volume history. `itch_l2_delta_book`
tracks displayed levels; `price_level_order_book`/`price_level_ioc_matcher` maintain
or consume quotes and emit fills. `pretrade_credit_ledger` reserves/release64-bit
gross amounts but retains neither executions nor positions. `multi_venue_quote_state`
retains only current source quotes. `ram_hash_table`/`ram_ordered_dictionary`
provide maps, not corrected OHLCV. Legacy `statistics_stream` computes signed16
power/absolute mean/peak in sample blocks/windows; `stream_window_minmax` retains
recent samples by arrival, `stream_run_reduce` reduces consecutive equal keys,
and `prod_minmax_signed32` is pairwise extrema. None handles retained match IDs,
broken tombstones, corrections or per-symbol open/close ordered by audit key.
Canonical and legacy RTL were searched before selection; no such service found.

Candidates considered: incremental cached totals/extrema need invalidation and
rescans after removing extremes, plus per-symbol metadata and multiword commit.
A parallel CAM/all-record multiply tree duplicates wide compute. Chosen bounded
full scans use one selected-address RAM, one multiplier and one accumulator;
mutation performs identity scan then virtual candidate aggregation before a
single row write or BUST bitmap update. Queries scan once; GET scans identity
only. Product is registered separately from the accumulation cycle, preserving
a clear multiplication/adder boundary. This costs three clocks/aggregate row.

Rows are `{symbol32,match64,sequence64,price32,quantity32}`=224bits. Retained and
active bitmaps are separate; broken records keep their identity and payload.
No RAM reset/sweep is needed in this core. Default/max payload7168/14336bits and
bitmap64/128bits; all other state is bounded scalar work/result/context data.
The actual example adds two8-entry128-bit hash payloads plus2-bit metadata per
slot:2080bits, and the trade core uses1792 payload/16 bitmap bits. Child hash
reset sweeps take8 clocks. No external memory or vendor hard block is required.

Numeric proof: maximum volume=64*(2^32-1)=2^38-64; maximum notional=
64*(2^32-1)^2=2^70-2^39+64. Each product is unsigned64, then zero-extended to70.
Count7 covers64, all public counts32. Lexicographic keys concatenate sequence64
then full match64. No timestamps, rounding, division or approximate VWAP.
Correcting does not move a trade in chronology. Price0 remains a legal extreme.

Risk MEDIUM:224-bit RAM packing, single32x32 multiply and70-bit accumulation/
128-bit order-key comparison paths require future physical assessment. No LUT,
BRAM, DSP, frequency, power or PPA measurement is claimed. The core source bound
is5N+4 clocks for mutation; the finite watchdog5N+8 gives local scheduling margin.
The wrapper's conservative500-clock result bound covers the8-order hash worst
case plus8-entry statistics and two invalidation handshakes. Arbitrary output
stalls remove any unconditional transaction deadline.

The actual example adds execution statistics only after the real order result,
using E display price versus C execution price and printable eligibility. A
post-book ADD rejection cannot be rolled back; both children are invalidated
before public completion. BUST/CORRECT never touches orders. This boundary and
retained capacity are explicit; there is no promise of a complete Nasdaq tape,
protocol decoder, cross-trade policy, automatic expiration or full-day history.

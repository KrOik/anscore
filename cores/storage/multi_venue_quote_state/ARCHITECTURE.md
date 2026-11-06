# Source-derived architecture and semantic difference

Baseline a68ca46815777c15c638c42a03899c83385bf052. Root approved this capability
before implementation. Whole public widths and source BBO quantities are kept.

The core maintains source identity and replaces its entire absolute quote. The
existing single-book L2 service instead combines order deltas by (side,price).
A source quote changing price must remove its old contribution and preserve
other sources independently. Venue-wide disable and epoch invalidation must
exclude every old quote without remembering a host-generated subtraction list.
These are the independent functional increments.

Semantic inventory covered all current package directories, production
RTL/SPEC/README and old components/systems/assets/deliverables/models/host/docs.
Focused actual source/spec reads included:

| Neighbor | Existing boundary |
| --- | --- |
| itch_l2_delta_book, itch_order_bbo8 | Single-symbol single-book aggregate and cached BBO; sequence is only an audit echo |
| price_level_order_book, quote_ioc16, IOC matcher | Price-level storage and matching; no source ownership or venue epoch |
| ram_range_min_index | Dense range assignment/argmin; no optional quote sides, source lifecycle or tie-quantity state |
| ram_ordered_dictionary / hash table | Generic key bindings; no source contribution replacement or quote eligibility |
| stream_topk, ips_topk_argmax4, minmax_signed32 | Frame/vector or scalar extreme selection, not persistent venue quotes |
| replay window / Mold recovery | Sequence classification or missing-prefix request lifecycle; no quote aggregation |
| deadline scheduler / credit ledger | Event deadlines or ticket holds; no BBO/quote source ownership |
| prefix / ternary tables | Header predicates; no price/quantity ordering |

No multi-source quote lifecycle implementation was found by NBBO/venue/BBO/
quote-consolidation/price-collar searches. The new RTL does not extend an old
width, rename a reducer or introduce a generic second dictionary/tree.

One unchanged canonical synchronous single-port RAM stores SYMBOLS*VENUES rows
of272 bits: pad2|epoch64|sequence64|bid_valid1|ask_valid1|bid_price32|ask_price32|
bid_quantity38|ask_quantity38. Default64 rows require17408 payload bits; maximum
256 rows require69632. A live bitmap adds64/256 bits. Per-venue epoch64 and two
configuration masks add264/528 bits at default/max. Scalar candidate/result,
indices and BBO accumulators are additional bounded registers; no payload reset
or context scan is required at startup. Constant VENUES<=8 is used only in the
flat address calculation after index checks, not as a variable data multiplier.

A command reads one target row for PROBE, or exactly VENUES rows for UPDATE and
QUERY. Eligibility and source-sequence checks finish before the one UPDATE
write. QUERY accumulates two price extrema, two41-bit exact sums and8-bit masks.
Update substitutes the candidate for its own source while scanning other rows.
No intermediate BBO is public before all checks/write ACK complete. There is no
CAM, sorted shift, hash lookup, multiplier/DSP datapath, divider, external RAM
or vendor primitive. A tree or parallel comparator bank would add update/valid
bookkeeping without benefit for at most8 sources and this serialized interface.

Source-derived first-valid latencies after acceptance are0 clocks for immediate
management/front-end errors,2 for PROBE,2*VENUES+1 for QUERY and2*VENUES+3 for a
successful UPDATE. The finite TB uses the conservative2*VENUES+8 bound (max24).
Held results extend the owner without limit; no device frequency, steady market
line-rate or unconditional transaction deadline is claimed. Earliest subsequent
admission follows response retirement by one clock.

The actual example has2*8*72+2*272=1696 payload RAM bits. Existing L2 APPLY has a
2*8+10 first-valid bound; PROBE, quote UPDATE and wrapper transitions produce a
conservative64-clock example bound, independently checked by its finite TB.
Both L2 instances share the same normalized tick/quantity units for the symbol.
An outer owner prevents any change between PROBE and UPDATE; PROBE alone is not
an inter-client reservation. A local failure or quote-update rejection is
followed by a venue DISABLE response before publishing the final error.

Resource risk LOW for default logical storage, MEDIUM for wide272-bit RAM
packing, source-metadata fanout and serial service. These are architecture
judgments, not measured LUT/FF/BRAM/DSP/power/Fmax or device-fit evidence.

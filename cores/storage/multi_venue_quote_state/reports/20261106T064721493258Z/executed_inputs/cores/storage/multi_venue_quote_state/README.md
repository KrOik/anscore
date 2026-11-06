# Multi-source absolute quote state

`multi_venue_quote_state` retains a complete absolute bid/ask quote for each
bounded (symbol,venue) identity. It atomically replaces both sides, rejects old
source epochs/sequences, excludes disabled sources and reports the consolidated
best prices, exact quantities at those prices and contributing venue masks.
`example/dual_venue_l2_quote.sv` connects two actual unchanged L2 books.

Status before execution: RTL_CANDIDATE, INTEGRATION_CANDIDATE, HW_UNVERIFIED.
Only the frozen finite qualification can establish LINT_PASS/UNIT_SIM_PASS.
No synthesis, PnR, STA, board or inherited regression is part of this package.

## Domain and interfaces

SYMBOLS is1..32, default16; VENUES is1..8, default4; TAG_W is1..32, default8.
Derived widths are private. Both public indices are unsigned32 and are checked
before narrowing. Symbols are dense caller-assigned IDs. Every source must use
the same price-tick and quantity units for a given symbol; symbol mapping,
currency conversion, lot rules and eligibility filtering belong upstream.

Prices are full unsigned32, including0 and all ones. Per-source quantities are
full unsigned38, retaining the existing ITCH L2 output width. An enabled quote
side requires positive quantity. An invalid side ignores its input price/size
and stores canonical zeros. Both sides invalid is a sequence-bearing withdrawal.
Opposite sides may be locked or crossed and are preserved without a trade.

Epoch and sequence are full unsigned64 with ordinary numeric, nonmodular
ordering. Initial epoch/sequence0 and all ones are legal. Epochs belong to a
whole venue, while the latest sequence belongs to each (symbol,venue) row.
A new venue epoch makes every old row for that venue ineligible immediately;
no row sweep is needed. There is no implicit rollover or automatic time policy.

One rising-edge clock, synchronous active-high reset, ordinary ready/valid and
no CE/CDC. A source keeps valid and all fields stable until acceptance or reset.
An accepted command owns the service until its result retires. Results remain
stable under unlimited backpressure. There is no retirement-edge fallthrough;
the next command can transfer on the following edge. A mutation is complete
before first result valid; result ACK releases an already completed operation.

Reset immediately masks c_ready/r_valid/busy and its active edge clears all row
ownership, venue configuration and held work/results. Payload RAM is not reset
and is hidden by the cleared live bitmap. The private reused RAM has clk_en=1
and rst_n=!rst; reset must span an active edge for the whole composition. Reset
discards the entire epoch, including earlier accepted updates; it is not rollback.

| c_op | Operation | Relevant fields |
| --- | --- | --- |
| 0 | CONFIG_VENUE | venue,epoch |
| 1 | DISABLE_VENUE | venue |
| 2 | PROBE | symbol,venue,epoch,sequence |
| 3 | UPDATE | symbol,venue,epoch,sequence and complete bid/ask pair |
| 4 | QUERY | symbol |
| 5 | CLEAR_ALL | none |
| 6..15 | BAD_OP | none |

CONFIG accepts any first epoch. Subsequent CONFIG requires a strictly greater
epoch, even while disabled, and enables the venue. DISABLE requires configured
venue, is idempotent, retains its epoch and raw rows, and excludes all its rows.
Re-enabling requires CONFIG with a greater epoch; retained old rows never revive.
CLEAR_ALL invalidates every row and source, permitting an explicitly new epoch
space. There is no timer or automatic re-enable.

PROBE performs the same identity/epoch/sequence eligibility check as UPDATE
without checking quote quantities or modifying a row. It supports an outer
owner that validates a source header before mutating its upstream book. Equal
or backwards sequence is STALE when a row exists in the configured epoch; the
first sequence after an epoch change may be any unsigned64 value. Sequence0
history is distinguished by r_has_previous. PROBE is a read-only observation,
not a reservation against other clients: the outer owner must prevent changes
between PROBE and UPDATE, as the actual example does.

QUERY scans all venues of one symbol and includes only live rows belonging to
configured/enabled sources at their current epoch. Best bid is maximum price;
best ask is minimum price. Quantities at the winning price are summed exactly
in41 bits:8*(2^38-1)=2^41-8. Source masks are8 bits, with all nonexisting venue
bits zero. Empty sides return valid0, price/quantity/mask0. Empty QUERY succeeds.
`r_locked` means both sides exist at equal prices; `r_crossed` means bid>ask.
There is no cached quote that can outlive a source disable/epoch change.

Every result echoes op/symbol/venue/epoch/sequence/tag, including ignored input
fields. `r_quote_valid` is1 only for successful UPDATE/QUERY; their BBO is the
post-command snapshot. All other results have zero BBO/flags. PROBE/UPDATE can
return r_has_previous/r_previous_sequence when the current-epoch source row was
read, including STALE. Earlier errors return these fields0. BACKEND_FAULT zeros
them. QUERY and management results return them0.

| r_status | Meaning |
| --- | --- |
| 0 | OK |
| 1 | BAD_SYMBOL |
| 2 | BAD_VENUE |
| 3 | NOT_CONFIGURED |
| 4 | DISABLED |
| 5 | BAD_EPOCH |
| 6 | STALE |
| 7 | BAD_QUOTE (a valid side has quantity0) |
| 8 | BACKEND_FAULT |
| 9 | BAD_OP |

Priority is opcode, CLEAR_ALL, venue management, symbol, QUERY, venue,
configured/enabled/epoch, UPDATE quantity, then previous-sequence validation.
Thus bad quote quantity precedes stale sequence. Expected errors change no
state. Every live row read is checked for canonical payload/padding, including
disabled or old-epoch rows; corruption yields BACKEND_FAULT. Memory/controller
hardware faults have no rollback guarantee after a private write. There is no
fault injection interface or persistent hardware-fault recovery mechanism.

## Actual dual L2 composition

The example fixes one symbol and two unchanged `itch_l2_delta_book(LEVELS=8)`
instances. Public operations are0 CONFIG,1 DISABLE,2 APPLY compound remove/add,
3 QUERY;4..7 are BAD_OP. All echo metadata retain their full public widths.

CONFIG first commits the new quote epoch, then CLEARs the selected actual L2
book. An invalid CONFIG does not clear that book. APPLY first PROBEs the latched
source header, then applies the compound pair to the selected L2, then UPDATEs
the quote service with that actual complete BBO. A failed PROBE never reaches
the local L2. One outer owner prevents every management or APPLY interleave
through these stages and the final held result.

Any L2 error triggers DISABLE of that source before publishing completion. If
the local L2 committed successfully but the subsequent quote UPDATE fails, that
source is also disabled before completion. The local mutation is retained;
there is no rollback or reconstruction from the aggregate. CONFIG with a new
epoch clears the corresponding L2 and starts recovery. A later QUERY observes
the remaining eligible venue(s). Error results have quote_valid0.

Three separate statuses must be inspected: r_quote_status is the PROBE/UPDATE
or management result; r_l2_status is the selected local-book result when
r_l2_touched=1; r_isolation_status is the DISABLE result after an error.
For an L2 failure, quote_status can be0 while l2_status is nonzero. r_disabled=1
acknowledges a successful explicit DISABLE or error isolation. Status0 without
r_l2_touched means no local-book operation took place. Successful CONFIG and
DISABLE have quote_valid0; successful APPLY/QUERY publish a consolidated quote.
The example has no public CLEAR_ALL; reset clears the entire composition.

This is normalized quote state, not a UTP decoder or a complete SIP/NBBO
implementation. Quote-condition, protected/odd-lot, trading-status, timestamp,
regulatory eligibility and venue liveness policies belong to the caller.
No price routing, matching, fee calculation, network transmission or timer is
added. A failing canonical private memory is outside the expected-error model.

## Finite qualification

Resolve files.f and example/files.f from this package root. Both are complete
offline source lists; existing shared RTL is unchanged. `run_checks.py
--write-plan` hashes sources/tools only, with zero oracle calls. C's independent
source-only review and root authorization are required before execution.

The one approved run archives exact15 inputs and the plan before3 independent
dictionary/min/max oracle vector-generation calls. All3 vectors are frozen
before any HDL child. A durable started receipt precedes archive work; each
child has a durable active checkpoint and raw stream/source/plan/tool hashes.
Before each child and at end, exact source/archive/plan/vector/tool hashes are
rechecked. The fixed matrix is3 syntax checks plus3 core compile/sim pairs and
1 actual example compile/sim pair:11 children/4 simulations. Core profiles are
(SYMBOLS,VENUES,TAG_W)=(1,1,1),(5,3,8),(32,8,32). Each child is bounded by20
seconds, process-tree termination5 seconds and drain2 seconds. First failure
stops; there is no automatic retry, repair, expansion or successful-profile rerun.

Core vectors cover every row, source epoch/disable/re-enable, source sequence0
and all ones, duplicate/backwards updates, all public operations and priority,
full32-bit invalid indices, valid price0/all ones, maximal38-bit tie sizes,
locked/crossed/empty books and deterministic mixed operations. Every vector
response is held6 clocks with an actual future QUERY offered and held through
admission; its independent snapshot is checked and held6 clocks too. Four live
directed resets interrupt before read request, read response, write response
commit and held result; fresh PROBE/QUERY confirm no stale ownership.

The actual example checks27 directed operations plus5 recovery CONFIGs and a
final QUERY, each followed by a real future QUERY:66 checked responses and33
future handshakes. It also accepts5 reset-cancelled operations (71 total
accepted), observes21 checked local L2 transactions,2 disabled results,267 held
clocks,132 blocked-future clocks and6 resets. Cases prove stale APPLY/invalid
CONFIG cannot mutate the book, natural local underflow disables the source,
new epoch recovery, >32-bit exact quantities, same-key compound updates and
ownership through held results. Reset probes target committed quote CONFIG
before local CLEAR, actual PROBE read response, actual L2 write response,
actual quote UPDATE write response and held public result. No unrun case is PASS.

# Venue-confirmed order risk reservations

Original bounded order lifecycle IP. A NEW order reserves its entire quantity
before transmission. A CANCEL_REQUEST does **not** free risk: fills can still
arrive while cancellation is pending. Only a venue rejection or cancellation
confirmation releases the corresponding unfilled quantity. Position survives
fills and cancellation. Full 112-bit OUCH tokens are compared without truncation.

Authoring state: RTL_CANDIDATE / SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED.
The frozen finite plan needs exact root and independent peer source approval
before any oracle, model import, AST, compilation or simulation is executed.

`order_risk_reservation` instantiates the unchanged `position_limit_reservations`
and its actual shared synchronous RAM. It adds pending-new, acknowledged-live
and pending-cancel states, full-token lookup and normalized venue transitions;
it does not duplicate signed position arithmetic. The ledger checks both
`position + buy_open <= max` and `position - sell_open >= min`; opposite orders
never net. Price, cash/notional, margin, fees, settlement, persistence, trade
busts and replacements are outside this service.

Parameters CONTEXTS=4 (1..16), ORDERS=8 (1..32), TAG_W=8 (1..32), including
non-powers of two. Invalid parameters deliberately fail elaboration. Context
indices are full unsigned32; applications map account-symbol pairs to them.
Positions and limits are signed64, quantities unsigned32, positive where used.
There is no scaling, floating point, saturation or rounding. Tokens include
zero and all ones. Tokens are globally unique while retained and reusable
after retirement; there is no daily token-history or replay suppression.

One clock, no CE/CDC, asynchronous active-low `rst_n`; release reset
synchronously and hold it through a clock edge (the example decoder uses a
synchronous active-high reset adapter). Reset starts a fresh empty,
unconfigured epoch, cancels owned operations and held results, and does not
promise rollback to an earlier order state. Payload arrays/RAM are not reset;
cleared ownership prevents stale data from becoming visible.

Every transfer is ordinary valid && ready. One command owns the core through
held response retirement, without same-edge fallthrough. Inputs must remain
stable while blocked. Output fields, token, tag, live count and fault state
remain stable under response stalls. No timeout is implemented in hardware.

| c_op | Operation | Significant input / rule |
| ---: | --- | --- |
|0|CONFIG|context, position, min/max; no open reservations in this context|
|1|NEW|context, full token, buy, positive quantity; creates pending-new|
|2|ACK|token, buy, quantity must match pending-new exactly; becomes live|
|3|REJECT|token must be pending-new; releases full remaining hold|
|4|CANCEL_REQUEST|token must be live; becomes pending-cancel, hold unchanged|
|5|CANCEL_ACK|live or pending-cancel token, positive decrement <= remainder|
|6|CANCEL_REJECT|pending-cancel token; becomes live, hold unchanged|
|7|FILL|live or pending-cancel token, positive quantity <= remainder|
|8|GET_ORDER|token; returns saved state and context snapshot|
|9|GET_CONTEXT|context; returns exact ledger snapshot|
|10|CLEAR|clears all state/fault; requires fresh CONFIG|
|11|INVALIDATE|sets sticky fault, retains all state and reservations|

FILL changes actual position and consumes only its fill quantity. CANCEL_ACK
never changes position: a partial cancellation leaves a live order with the
smaller reservation; full cancellation removes it. An unsolicited venue cancel
is accepted for a live order. Either a partial or full confirmation completes
the pending-cancel state; this API has no independent cancel-request quantity
or exchange cancel-request ID. A complete FILL removes the order even while
cancel-pending. A subsequent cancel/reject/fill for its missing token returns
NOT_FOUND and never applies a second release or fill. No out-of-order buffer,
automatic idempotence, retransmission or venue-sequence recovery is claimed.

Outputs r_op/token/tag always echo the request, including errors. Successful
row operations return saved context/direction, post-operation remaining/phase
(0 absent,1 pending-new,2 live,3 pending-cancel), and the post-context position,
limits and directional open totals. Successful CONFIG/GET_CONTEXT have row
fields zero. CLEAR/INVALIDATE and all errors have snapshot fields zero.
`r_live` is the wrapper's retained-order count, including errors; after an
internal backend fault it is retained metadata, not a certified recovery
snapshot. `faulted` remains sticky until CLEAR/reset. Every faulted request
except CLEAR/INVALIDATE returns a retirable INVALID_STATE response.

Statuses0..12 retain the ledger meanings:0 OK,1 BAD_CONTEXT,2 NOT_CONFIGURED,
3 BAD_QUANTITY,4 DUPLICATE,5 LIMIT_EXCEEDED,6 FULL,7 NOT_FOUND,8 BAD_LIMITS,
9 INVALID_STATE,10 OPEN_RESERVATIONS,11 BACKEND_FAULT,12 EXCESS_QUANTITY.
13 BAD_STATE covers lifecycle/ACK-field mismatches,14 BAD_OP,15 INTERNAL.
Ordinary errors preserve state. CLEAR/INVALIDATE dominate other checks, then
faulted, unsupported op. NEW tests full-token duplicate then wrapper capacity
before ledger context/quantity/configuration/limit checks. Other row operations
test existence, then lifecycle, then positive/bounded quantity. ACK ignores
context but checks supplied direction and quantity. All other token operations
inherit saved context/direction regardless of supplied values.

Partial CANCEL_ACK privately executes ledger CANCEL then RESERVE of the
smaller remainder. The single owner prevents public access to that gap. With
no interleaving, smaller quantity, unchanged position and the freed slot, the
second reserve is logically guaranteed to fit. Unexpected private replies
isolate the epoch before returning INTERNAL. No multiword hardware-fault
rollback is claimed. CLEAR requires application reconciliation with venue
orders; it is not itself an exchange cancellation.

## Actual OUCH combination

`example/ouch42_order_risk.sv` instantiates the committed OUCH4.2 server decoder
and this service. Local commands have priority over a complete decoder event;
the decoder may receive/hold one message while a local transaction owns risk.
Every local/venue transaction owns the example through the single public result.
Local commands include NEW before the external application transmits an order,
and CANCEL_REQUEST before it transmits a cancel. This example does not encode
or transmit outbound order/cancel bytes and does not infer successful network
transmission from a reservation response.

Valid A (live order state L) maps to ACK, E to FILL, C to decrement CANCEL_ACK,
J to new REJECT, S to an informational result without risk mutation. Full
14-byte tokens are connected directly. Side B is buy; S/T/E are sell.
Dead-state A, U replacement and other unsupported successful decoder events
produce example status17 and INVALIDATE. Decoder failures produce status16
and INVALIDATE. Any venue lifecycle error first drains its response, then
INVALIDATE, and returns the original risk status with stage2 and zero snapshot.
This retains holds conservatively. Local errors have stage0 and do not trigger
automatic invalidation. `r_venue/type/decode_status/tag` identify the source;
stage0 includes normal results and informational S. S uses r_op15 and zero
snapshot, not a core BAD_OP request. No cancel-reject wire message is included
in the reused decoder subset: the application may issue normalized op6 after
independently validating its venue cancel-reject notification.

Raw OUCH framing has no Soup/network session recovery in this example. The
controller must detect session/gap errors and INVALIDATE/reconcile a common
epoch. Reset clears decoder and risk together. Replays, A/E/C/J ordering,
duplicate suppression, stock/token uniqueness, short-sale controls and risk
configuration remain application obligations.

## Offline verification contract

Resolve both explicit source lists from this package root. No nested -f,
includes, generated HDL, ROM images, vendor primitive or network runtime is
required. Three exact unchanged dependencies are listed in SOURCES.md.

The dictionary oracle uses Python unbounded integers, recomputes open totals
from live orders and never imports RTL or reads simulator output. Three
profiles1/1/1,3/5/8,16/32/32 cover full token width, extreme signed positions,
full quantity32, capacities, both directions, pending cancel/fill/partial ack,
ordinary errors and state queries. The TB checks every result and holds it for
four clocks while a genuine next request stays offered. Four reset probes
cancel private send/wait, held result and partial-cancel release/re-reserve gap.
The actual decoder example uses hand-derived wire messages/results and reset
probes; it checks conservative retained holds on malformed/unsupported events.

The exact finite matrix is3 oracle preparation children,3 syntax checks,
3 core compile/simulation pairs and1 example compile/simulation pair:
14 children,11 HDL,4 possible successful simulations. Each child has20s,
tree termination5s and sole target exit observation2s, with final nonwaiting
helper poll. PID/terminal JSON/raw streams are durable before parsing.
First failure stops all later launches; guard/reports block any automatic
retry. Frozen sources, tools, controls, vectors, original images and raw
evidence are retained. Synthesis, PnR, STA, board, PPA and inherited regressions
are not part of this plan. Actual maturity depends on later immutable receipts.

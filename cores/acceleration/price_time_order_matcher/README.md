# Bounded per-order price-time limit matcher

Original single-instrument active matching service. NEW_LIMIT walks actual
resting orders, executes at the maker's price in best-price then same-price
FIFO order, and rests any positive remainder. CANCEL and GET use the complete
64-bit order ID. Individual maker identity, residual quantity and FIFO lifetime
remain available across commands; this is the increment missing from the
existing aggregated level book/IOC controller and feed-driven ITCH order state.

Authoring state: RTL_CANDIDATE / SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED.
No model, preparation, HDL, synthesis, PnR, STA, board, PPA or historical
regression has run. Only independently reviewed exact root/peer gates may
execute the later finite plan. Baseline is
`05b9614c3962e9d4ae934c4b9c7bd315cc01aed4`.

## Domain and deliberate capacity policy

ORDERS defaults16 and is1..32, including non-powers of two. PRICE_W, QTY_W
and TAG_W default32/32/8 and are each1..32. Unsupported parameters fail
elaboration through a named missing module. Order ID is always unsigned64;
zero/all ones are ordinary IDs, unique only while live. Price and quantity
are exact unsigned integer ticks/lots; price0/all ones are legal. NEW quantity
must be positive. There is no rounding, float, saturation, signed price,
currency, stock/session decoding or market/IOC order flag.

Every NEW must reserve an already free order slot **before any fill**. A full
book therefore rejects NEW with FULL even if that order could have traded
immediately. A duplicate ID is checked before FULL; quantity0 is checked before
the ID lookup. This conservative storage policy prevents a partial execution
followed by a residual-capacity failure. ORDERS1 can retain one order but cannot
admit a taker while that order is live. Slot reuse never changes time priority:
a newly resting residual is appended behind all older live orders.

## Interface and transaction contract

One rising-edge clock, no CE or CDC. rst_n is asynchronous active low; assert
it through a rising edge because the reused hash has a synchronous reset.
Release synchronously. Public ready/valid is masked during reset. The hash
clears HASH_SLOTS metadata rows after release; no command is accepted until it
is ready. Payload RAM is not reset and cannot be read through cleared live
ownership. Reset discards the entire book epoch and cancels pending outputs.

Commands transfer on c_valid&&c_ready. c_op is0 NEW_LIMIT,1 CANCEL_ID,2 GET_ID,
3 CLEAR;4..7 BAD_OP. Fields are c_order64, c_sell (0 buy/bid,1 sell/ask),
c_price[PRICE_W], c_quantity[QTY_W] and opaque c_tag[TAG_W]. CANCEL/GET use
only order/tag; CLEAR uses only tag (op/order are still echoed). NEW captures
every field on acceptance. Ignored inputs never affect a lookup or cancellation.

| Output | Meaning |
|---|---|
| f_valid/f_ready | One strictly positive trade for one resting maker |
| f_taker/f_maker64 | Full aggressor and resting order IDs |
| f_sell/f_price/f_quantity | Taker direction, maker execution price, executed lots |
| f_taker_remaining/f_maker_remaining | Exact remainders after this fill |
| f_index32/f_tag | Zero-based fill index and aggressor's command tag |
| r_valid/r_ready | Exactly one final response, after all its fills retire |
| r_op/r_order/r_tag | Command identity echoed even on error/CLEAR |
| r_status4 | 0 OK,1 BAD_OP,2 BAD_QUANTITY,3 DUPLICATE,4 FULL,5 NOT_FOUND,6 FAULTED,7 BACKEND_FAULT |
| r_sell/r_price/r_remaining | NEW direction/limit/rested remainder; GET retained record; CANCEL saved direction/price with remainder0 |
| r_filled/r_fills32 | NEW total execution and number of maker fills; otherwise0 |
| r_cancelled | CANCEL's removed remaining quantity; otherwise0 |
| r_live32 | Exact post-command resident-order count, including on errors |

CLEAR and every error return sell/price/remaining/filled/cancelled/fills0.
An empty CLEAR succeeds; missing GET/CANCEL returns NOT_FOUND without mutation.
Malformed/duplicate/full NEW emits no fill and changes no state. NEW's
filled+remaining equals its requested quantity. All sums/subtractions are exact
within QTY_W because total executed never exceeds that request. At most ORDERS
makers can be consumed. No fill LAST is needed: the final response terminates
the transaction even when it had zero fills.

One accepted command owns the complete core until response retirement. No later
command, GET or CLEAR can observe private hash/RAM/list updates. There is no
same-edge response retirement/admission fallthrough. Output valid and **every**
associated field remain stable under arbitrary sink stalls. The input producer
holds its offer until acceptance/reset. Fills retire in price-time order; a
stalled fill blocks further matching and all input admission.

Each maker update is committed before its fill becomes visible. A held fill
already consumed that maker's quantity. Reset is cancellation of an epoch,
not rollback of trades already accepted externally. A consumer must reconcile
or discard an incomplete transaction prefix when reset removes its completion;
it must never infer that an accepted earlier fill was reversed. No persistent
journal, replay, idempotence, undo or transport recovery is supplied.

The normally unreachable BACKEND_FAULT isolates an inconsistent internal
reply/link by setting sticky faulted. Normal requests then return FAULTED;
CLEAR remains reachable, clears the epoch and fault. BAD_OP still returns
BAD_OP while faulted. An internal partial write is not rolled back.

## Architecture and service limits

The unchanged ram_hash_table maps full IDs to order slots. The unchanged
cip_sync_sp_ram stores packed order records. One global singly linked FIFO
orders the live records by time of resting admission. Every match scans that
list and replaces its candidate only at a strictly better price. The first
encountered same-price maker wins, including after partial fills, arbitrary
cancellation, holes and physical slot reuse. No wrapping timestamp or host
sorting is required. No existing dependency source is modified or copied.

One RAM request and one response are drained per operation, with clk_en tied1.
Appending patches the old tail, cancellation/depletion patches a predecessor,
and one owner hides their multi-write interval. Hash lookup is serialized;
tombstones affect latency, not usable live capacity. Matching may scan N rows
for each of N fills: worst work is O(N^2), cancellation O(N), hash operation
O(HASH_SLOTS). There is no one-command/one-fill-per-clock claim. Unlimited
output stalls remove an unconditional whole-transaction completion bound.

Logical arrays use N*8*ceil((64+1+P+Q+IW+1)/8) order bits plus
HASH_SLOTS*(64+IW+2) hash bits, where IW=max(1,ceil(log2(N))) and HASH_SLOTS
is the smallest power of two at least N. Defaults use3296 bits; max N32/P32/Q32
uses6624 bits, plus live bitmap, command/candidate/row/response and FSM registers.
No multiplier, divider, external memory, parallel order CAM or sorting network
is added. Physical RAM packing and timing are unmeasured; storage risk LOW,
serialized latency/control risk MEDIUM. No device-fit or speed claim is made.

## Fixed finite verification source

The three core profiles `(N,P,Q,T)` are `(1,1,1,1)`, `(5,9,7,4)` and
`(32,32,32,32)`. Their literal fixture generators describe43/116/413 commands
and0/9/36 maker fills, respectively. The independent oracle uses an ordinary
insertion-ordered Python list and price sorting, without the RTL's hash, RAM,
slot addresses, links or FSM. No oracle call has yet run.

The core TB compares every completion and fill field, stalls each fill four
cycles and every completion five cycles, and prefetches the genuine next
command into a continuously held offer behind the stalled completion. Directed
fixtures cover zero/all-ones IDs/prices/quantities, conservative FULL, duplicate
and zero-quantity precedence, exact/missing cancellation, arbitrary list
deletion and slot reuse, partial maker FIFO, better price over older time,
maker-price execution, same-side/noncrossing preservation, and full/empty reuse.
The maximum fixture consumes31 distinct makers in a single sweep.

Six explicit reset probes per profile cancel hash ownership, RAM ownership,
held completion, held fill (or the singleton FULL response), an uncommitted
resting-row write, and a final held suffix after one accepted fill in the
ragged/maximum profiles. Singleton uses a held GET for that last probe. Each
probe checks an empty epoch and missing old ID before ordinary fixtures start.
The example TB checks actual two-client round-robin selection, a real blocked
second offer, owner-specific completion routing, same-price makers, held fills
and reset with a held client response. These are finite source plans, not PASS.

FINITE_PLAN.json fixes14 children: three once-only preparation calls, three
syntax checks and four compile/simulation pairs (three core profiles plus the
actual example). run_checks.py requires a separate root/peer SOURCE_REVIEW,
exact plan/seal/runner pins and the unchanged baseline before creating its once
guard. It freezes all source/dependency/control bytes before child execution,
saves exclusive raw streams and terminal records before parsing, and stops at
the first failure. Compiler images, including partial failed images, are kept.
Every simulation has its image SHA and prechecked flag in a distinct immutable
initial sidecar, fsynced before Popen. Each target has20 seconds, tree cleanup5
seconds and one sole2-second target-exit observation; cleanup kills are
independent nonwaiting actions. There is no automatic retry or cleanup deletion.

Both file lists resolve from this package directory and form the complete
offline HDL closure. The actual example arbitrates two clients into one real
book and routes the held completion to its owning client, while exposing all
real fills. It does not emulate a feed, a venue, risk or settlement service.

Amend is deliberately absent. Applications may CANCEL, consume its response,
then submit a NEW with fresh time priority; these remain two visible commands,
with no atomic replacement or guaranteed readmission. Self-trade prevention,
hidden/iceberg orders, auctions, market orders, risk, fees, settlement, feed
reconstruction and exchange certification are outside this bounded service.

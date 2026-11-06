# Persistent single-instrument ITCH order state

`itch_order_state` turns normalized ITCH5 A/F/E/C/X/D/U events into persistent
64-bit order-ID state: side, unsigned32 display price and remaining shares.
It checks lifecycle/capacity errors and emits one atomic old/new record result
with compound remove/add deltas. No host lookup, per-order side annotation or
record-address management is needed. This supplies the missing state between
the byte receiver and a future L2 aggregation engine.

It does not maintain summed price levels, match takers or build a complete
exchange feed handler. In particular, many unsigned32 order quantities can
need more than32 bits at one price. The existing price-level book supports
only32-bit quantity and lacks exact-price GET for transactional preflight;
this package makes no claim that that L2 loop is closed.

## Clock and ownership

One rising-edge clock, synchronous active-high `rst`, no CE or CDC. Public
readies/valid are suppressed while reset is high. An active reset edge cancels
all pending work/results, clears configuration and fault flags, empties both
hash tables and starts their ORDERS-clock metadata sweep. Inputs remain
blocked through that sweep. RAM payloads/read registers are not reset and
cannot become visible through cleared ownership. Reset is a new state epoch,
including cancellation during the private erase/put gap of Replace; it is
not rollback to earlier accepted orders. Every source holds valid and all
associated fields until acceptance or reset. Reset peers consistently.

Every transfer is ordinary `valid && ready`. Management wins a simultaneous
management/event offer. One command owns the state through held result
retirement; no later event/query can observe private intermediate updates.
Both readies are low while owned. The next request can transfer on the edge
following retirement, with no same-edge fallthrough. Every result field and
count remains stable under arbitrary output stalls. There is no timeout.
The two private hash ports are consumed independently, so one faster lookup
cannot cause the slower side's result to be missed. Mature CE-qualified peers
must use an adapter; both reused hashes already use standard handshakes.

## Management and recovery

| `c_op` | Meaning |
| ---: | --- |
|0 CONFIG|Clear both sides, load `c_locate[15:0]`/`c_stock[63:0]`, configured=1, faulted=0|
|1 CLEAR|Clear both sides and faulted, retain current configuration (including unconfigured)|
|2 QUERY|Look up full `c_order[63:0]` without changing state|
|3 INVALIDATE|Set faulted without changing retained orders/configuration|

All four operations return one held result with `r_admin=1`, `r_op=c_op`,
echoed request order/tag and sequence0. CONFIG/CLEAR/INVALIDATE succeed even
when already faulted or unconfigured. CONFIG becomes active only after both
clears complete. QUERY returns NOT_CONFIGURED or FAULTED without table access
in those states; otherwise missing QUERY is NOT_FOUND and does not poison.
Successful QUERY returns identical old/new snapshots with both delta flags0.

`configured`/`faulted` are synchronous level outputs, also stable throughout
each response. Faulted does not certify feed completeness; it records a
detected state/recovery failure. Every target event and QUERY still produces
a **retirable FAULTED response**, rather than permanently blocking upstream.
CLEAR or CONFIG always remains reachable once the held response is consumed.
The caller must restore a consistent snapshot/replay epoch before using a
cleared state as a complete market book. No GLIMPSE client or snapshot loader
is provided. CLEAR/CONFIG invalidate the whole epoch without per-order deltas;
any downstream aggregation must also reset/reseed its matching epoch.

## Event acceptance and numerical meaning

Event inputs are ASCII `e_type`, locate16, original/new order references64,
`e_sell` (0 bid/1 ask), quantity32, price32, stock64, audit sequence64 and tag.
These directly match the relevant normalized receiver fields. No LAST is
needed because one event owns one state transaction; packet sequence checking
already belongs to the receiver. Sequence is echoed, not checked for per-symbol
contiguity: skipped messages and other symbols legitimately create gaps.

All integers preserve unsigned wire bits, including order IDs0/all ones and
prices0/all ones. Shares are positive integer counts. Price units are ITCH's
implied decimal4 (1/10000), without floating point, rounding, clipping or
advertised exchange-price-ceiling validation. Only current live IDs are unique;
retired-ID reuse is permitted. There is no full-day used-ID history check.

Before configured, every event returns NOT_CONFIGURED. After configuration,
a different locate returns IGNORED **before** fault/type/field checks, with
no hash access or mutation. Thus irrelevant symbols continue draining even
while the target state is faulted. A target A/F must carry exactly configured
stock bytes (first ASCII byte most significant, including right spaces).
Other event types inherit the selected symbol and ignore their stock input.
Caller normalization must already have checked message lengths and B/S/Y/N
wire enumerations. This core's side is a single normalized bit.

| Event | State change |
| --- | --- |
|A/F|Reject existing live ID; insert side/price/positive quantity|
|E/C/X|Deduct positive input quantity from the referenced remaining quantity; reject underflow; delete exact zero|
|D|Delete the complete referenced order; quantity/price/side/new-ID inputs ignored|
|U|Remove old ID; install distinct unused new ID with new positive total quantity/price and inherited side|

C's execution price **does not change** the resting order's display price.
Its printable flag has no effect on book removal and is deliberately not an
input. E/C/X/D/U inherit side from retained state, ignoring their input side.
U inherits stock by single-symbol configuration. MPID, tracking, timestamp,
match number and trade-volume statistics are not retained; this is the order
state required for L2 reconstruction, not a full L3 audit record. Unsupported
target type, zero relevant quantity, target Add stock mismatch, or U's new ID
equal to old ID is BAD_EVENT. U collision is checked across both sides.

## Result, deltas and atomicity

`r_admin/op/request_order/sequence/tag` identify every accepted request,
including rejection/ignore. Successful event results provide optional old/new
records (`valid`, full ID, sell, price, quantity); absent records are all zero.
An Add has only a new record, deletion only old, partial cut both, and U both.
All ordinary errors/ignores have both records and delta fields zero.

`r_remove_valid` means subtract `r_remove_quantity` at the **old** record's
side/price. `r_add_valid` means add the **new** record's entire quantity at
its side/price. E/C/X remove only the deducted quantity even when the old
record held more; they never set add. U removes the complete old quantity and
adds the new total under a single held result, including same-price changes.
The receiver consumes that compound pair with one response handshake; it is
not two independently acknowledged deltas. A downstream engine must still
provide enough aggregate width/capacity and its own atomic update policy.

`r_count/bid_orders/ask_orders` are exact post-transaction live-order counts,
not price levels. They reflect cached actual child counts and remain held.

| `r_status` | Meaning |
| ---: | --- |
|0|Success|
|1|Different configured locate, ignored|
|2|Not configured|
|3|Faulted; target state requires recovery|
|4|Bad target event/type/quantity/stock/identical U references|
|5|Existing Add ID or U new-ID collision|
|6|Missing event reference or missing non-poisoning QUERY|
|7|New Add exceeds total live-order capacity|
|8|E/C/X quantity exceeds remaining shares|
|9|Unexpected inconsistent private reply; state faulted|

Event status4..8 sets sticky faulted and leaves both tables unchanged. Status2,
3 and1 do not mutate them. Rejection priority is unconfigured, ignored locate,
faulted, malformed relevant fields, old-ID existence/duplicate, then capacity/
underflow or new-ID collision. Admin missing QUERY leaves faulted unchanged.

All expected failures are decided before mutation. U prechecks old presence,
new absence on both sides, distinct IDs and positive quantity. It then privately
DELETEs old and PUTs new in the same side table; the deleted slot guarantees
space even when total capacity was full. No external request can interleave.
Only a confirmed final write publishes the successful compound result. This
is externally serialized transaction atomicity, not simultaneous physical
multiword write. An inconsistent post-mutation child reply sets INTERNAL and
blocks event/query access until recovery; no hardware-fault rollback is claimed.
Reset anywhere clears both tables/configuration together.

## Reuse, storage and timing

ORDERS is a power of two1..64, default32; TAG_W is1..32, default8. Unsupported
parameters elaborate a named missing module. Each side uses an unchanged
`ram_hash_table` with ORDERS slots, key64 and value64=`{price32,quantity32}`.
The side is implicit in the selected table, avoiding truncating a65-bit record
or widening mature code. Combined occupancy is limited to ORDERS, so all
capacity may belong to either side; it is not ORDERS per side. No record-pool
allocator, widened key variant or duplicate hash implementation is introduced.

Two payload/metadata arrays total `2*ORDERS*(128+2)` bits:8320 default/16640
maximum, plus child read/response buffers and wrapper scalars. Sequential
selected-address reads, complete linear probing and tombstones are retained.
No parallel all-key CAM, DSP, multiplier, external memory or vendor primitive
is added. Qualitative resource risk is **MEDIUM** from RAM width/packing,
wide metadata selection and collision-dependent latency; no PPA is measured.

With k probes per lookup, the reused hash needs2*k clocks for GET and2*k+1
for mutation. Both side lookups run concurrently and the slower one governs
the phase. Source-level response-valid bounds from acceptance are0 clocks
for immediate statuses/INVALIDATE, ORDERS+3 for CONFIG/CLEAR,2*ORDERS+3 for
QUERY,4*ORDERS+7 for Add/cut/delete, and8*ORDERS+14 for successful U. Earlier
rejections can be shorter. These are conservative FSM bounds, excluding reset
initialization and output stalls; earliest response transfer is one further
edge. Tombstones can make a miss scan every slot even at low occupancy.
Arbitrary sink stalls remove any whole-transaction deadline. No one-event-per-
clock, network wire-rate, hardware frequency or latency in nanoseconds is claimed.

## Actual receiver example and offline closure

Resolve `files.f` and `example/files.f` from this package root. Production
closure is this wrapper plus the canonical sibling hash once. The latter
list also adds unchanged B35 `moldudp64_itch_rx` and actual
`itch_receiver_state8`: UDP bytes ->256-byte receiver ->8-order state.
It exposes independent receiver configuration, state management, packet
completion and state response ports. All are ordinary same-clock handshakes.

Packet completion means parser admission/delivery, not successful state update.
The example deliberately does **not** infer recovery policy from a packet
error. Its controller must drain both response channels, detect receiver
gap/session/framing errors, submit INVALIDATE, then restore a common receiver/
state epoch through replay/snapshot and CONFIG/CLEAR as appropriate. Reconfiguring
the receiver alone never clears a faulted order state. The example simulation
performs Add, C with different execution price, U, gap/explicit INVALIDATE,
a faulted but retirable following event, CLEAR/reseed and a complete fresh Add.
There is no hidden automatic acknowledgement of a state error.

`python -B run_checks.py` copies/hashes all10 HDL/model/runner/list/dependency
inputs before model invocation, then fixes three ASCII vector sets before
the first tool. It runs default/max/example syntax, three core compile/sim
pairs and actual example compile/sim:11 finite children. Each has a20-second
hard limit, process-tree termination and bounded cleanup. Failure stops later
launches; an existing receipt prevents automatic retry. Work images/references
remain ignored for orchestrator closeout; the runner does not clean them.

The oracle uses an ordinary dictionary of ID→(side,price,quantity), without
hardware hashing/probes/FSMs. Profiles1/TAG1,8/TAG8 and64/TAG32 compare every
response field and the complete live contents of both private maps after each
completed transaction, including expected rejection preservation. Fixtures
cover all events/admin ops, full capacity/collisions/tombstones, full-table U,
high64 IDs, unsigned extremes, C price preservation, faulted/filter/recovery
and held real future requests through eventual acceptance. Four live reset
boundaries include the private U erase/put gap and held success/fault replies;
each is followed by a fresh configuration/lifecycle. No upstream code is run.

The first run `reports/20261106T035057204435Z/results.json` passed all11
children, with no failed/timed-out child or retry. The three profiles completed
249/269/381 ordinary commands, total899 (332 management and567 events), and
checked the complete private state after each response. Their held responses
occupied5394 clocks;884 real next requests were offered before retirement and
held through acceptance. Each profile also cancels four live operations by
reset, including U's private erase/put gap, for12 live reset probes plus the
three initial resets. Total profile run lengths3857/6605/26906 clocks include
testbench source/sink waits and reset activity; these are not service-rate data.
The actual receiver example passes6 packets and8 state/management results.

All10 current inputs and pre-tool copies,22 raw logs,3 frozen vectors,4 images
and both tool executables were SHA256-verified against that receipt. Compilation
has inherited-timescale warnings only. The selected evidence and exact
checked-to-delivered mappings are sealed in `B36_DELIVERY.json`; see
`QUALIFICATION.md` for coverage and limits. Maturity is LINT_PASS, UNIT_SIM_PASS,
INTEGRATION_CANDIDATE and HW_UNVERIFIED. No synthesis/PnR/STA, board run,
inherited large regression or full-market/exchange conformance test is performed.

# Atomic ITCH-delta L2 aggregation and BBO

`itch_l2_delta_book` consumes one compound remove/add pair and maintains bounded
price-level totals and the resulting best bid/ask. A single response publishes
the whole post-transaction quote, its change flags and level counts. It closes
the aggregation step after `itch_order_state` without changing mature order,
dictionary or RAM sources. It does not match orders or acquire a feed snapshot.

Current status is LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE alongside
HW_UNVERIFIED. The single authorized first run passed all11 planned children;
its scope is recorded below and in QUALIFICATION.md. No synthesis, PnR, STA or
board execution occurred.

## Numerical domain and capacity

Prices and each delta quantity are unsigned32. Aggregates are exact unsigned38:
64*(2^32-1)=2^38-64 fits without rounding or saturation. Every price pattern,
including zero and all ones, is legal. Side is 0 bid/1 ask. No tick/lot scaling,
price ceiling, signed price or decimal conversion is performed. ITCH-normalized
prices retain their implied decimal4 units. Repeated standalone updates may
exceed the 64-order bound; overflow of 38 bits is explicitly rejected.

LEVELS is total distinct (side,price) capacity,1..64, default32. All slots may
belong to either side. It is not capacity per side. TAG_W is1..32, default8.
Unsupported settings reference a named missing module. Quantity-zero levels
are absent. Opposite sides at the same price remain distinct. Crossed/locked
quotes are retained and reported without generating trades.

## Clock, ownership and reset

One rising-edge clock, synchronous active-high rst, ordinary ready/valid on all
public channels, no public CE or CDC. A source holds valid and all payload fields
until acceptance or reset. One accepted command owns the block through response
retirement. There is no same-edge retirement/admission fallthrough. Every valid
response bit, counts, BBO and faulted level remains stable under arbitrary sink
stalls. No next command can observe the private two-write interval.

Reset masks ready/valid immediately and clears ownership/live bitmap, caches,
counts and fault at an asserted rising edge. RAM payload is not cleared. The
private canonical RAM uses inverted asynchronous reset for its response slot;
rst must span a rising edge to cancel the whole composition. Deassert reset
synchronously at system level. This is not a reset synchronizer. Reset during
either private write discards the entire epoch, including prior completed work;
it is not rollback. Stale RAM rows cannot become visible through cleared live
ownership. CLEAR likewise invalidates the complete aggregation epoch and emits
no per-level deletion stream.

## Command and response contract

`c_op[2:0]`, two optional legs (`c_remove_valid/sell/price/quantity` and
`c_add_valid/sell/price/quantity`), `c_sequence[63:0]` and opaque c_tag form a
command. Sequence is audit echo only; the receiver owns sequence completeness.

| Op | Meaning |
| --- | --- |
|0 APPLY|Atomically subtract a positive enabled remove leg and add a positive enabled add leg; at least one leg required|
|1 GET|Exact lookup using c_remove_sell/price; ignore all valid/quantity/add fields|
|2 SNAPSHOT|Return cached BBO and counts without RAM access|
|3 CLEAR|Empty all levels, clear sticky fault, return the empty BBO|
|4 INVALIDATE|Set sticky fault and retain stored levels/BBO|
|5..7|BAD_OP without mutation or new fault|

APPLY first validates enabled quantities, then removal existence and sufficiency,
then addition overflow and final capacity. This order also applies when both
legs identify the same key: an insufficient removal cannot be excused by a large
addition. Same-key updates compute old-remove+add and retain one level. For
different keys, deleting the complete old level frees a slot for a new level
even when the book starts full. Reducing an old level without deleting it frees
no slot. All expected checks finish before any RAM write or metadata mutation.

| r_status[3:0] | Meaning |
| --- | --- |
|0 OK|Successful command|
|1 NOT_FOUND|GET missing, or enabled removal missing|
|2 BAD_DELTA|No enabled leg or zero enabled quantity|
|3 UNDERFLOW|Removal exceeds retained aggregate|
|4 FULL|New level cannot fit after the complete pair|
|5 OVERFLOW|Addition exceeds unsigned38|
|6 FAULTED|APPLY/GET/SNAPSHOT while sticky fault is set|
|7 BAD_OP|Unsupported opcode|
|8 INTERNAL|Unexpected RAM response/control failure|

Expected APPLY errors1..5 leave all rows, live bits, counts and BBO unchanged and
set sticky fault. Missing GET is non-poisoning. Faulted commands still return
retirable responses; CLEAR and INVALIDATE remain reachable. A FAULTED SNAPSHOT
retains the prior BBO fields. BBO valid bits describe retained levels, not feed
trust: consumers must also require faulted=0. INTERNAL faults invalidate trust;
after a private write no rollback guarantee is made. GET/APPLY are blocked by
retirable FAULTED results until CLEAR. Hardware fault rollback is outside scope.

Responses echo op/sequence/tag. GET success returns r_found=1 and r_quantity38;
all other cases zero those fields. Successful APPLY returns four quantities38:
r_remove_before/after and r_add_before/after at their respective input keys.
Both after fields describe the complete pair's final state, including same-key
updates; both before fields then equal the original aggregate. Disabled-leg
and error quantity fields are zero.

Every response also contains r_bid/ask_valid, r_bid/ask_price32,
r_bid/ask_quantity38, r_bid/ask_levels32, r_bid/ask_changed and r_crossed.
Absent best levels have zero price/quantity. Changed means the best validity,
price or aggregate quantity differs from before this successful APPLY/CLEAR;
other commands and errors report changed=0. A non-best update may change a
level without changing BBO. Crossed means both sides exist and bid>=ask.
There is one result per command and no independently acknowledged BBO stream.

## Architecture and source-derived timing

One unchanged cip_sync_sp_ram, DATA_WIDTH72, stores rows
`{pad1=0,sell1,price32,quantity38}`. A LEVELS-bit live bitmap and scalar caches
provide ownership. Every APPLY/GET scans all LEVELS addresses through the RAM's
request/response handshake, two clocks per row. The scan finds exact keys/free
space and accumulates the best unaffected levels. Two later cycles include the
post-update touched levels. At most two positive rows are written; zero rows
are removed through the final live bitmap commit. Each write response is
confirmed before proceeding. Write response payload is read-first and ignored.
The RAM's private clk_en is tied1, so no public CE/ready mismatch exists.

Payload storage is72*LEVELS bits:2304 default,4608 maximum, plus at most64 live
bits, small indices/counts and command/touched-row/BBO scalar registers. There
is no all-key CAM, hash copy, sorted shift, slot allocator, multiplier, divider,
vendor primitive or external memory. Resource risk is MEDIUM for 72-bit RAM
packing, comparator/control routing and serialized O(LEVELS) service. These are
structural budgets, not measured LUT/BRAM/Fmax/power results.

Response-valid source bounds from acceptance are0 clocks for immediate statuses,
SNAPSHOT/CLEAR/INVALIDATE; GET uses2*LEVELS+1; successful APPLY uses at most
2*LEVELS+10. Earlier failures are shorter. Earliest response transfer is one
further edge. These count the actual private RAM handshakes and exclude reset
and external stalls; no independent timing assertion has run. Unlimited sink
stalls remove any whole-transaction deadline. No market line rate is promised.

## Actual order-state connection and offline closure

Resolve both file lists from this package root. Production closure is core plus
canonical RAM. The example also lists unchanged itch_order_state and its hash
dependency once each. `itch_order_bbo8` accepts normalized ITCH events and all
four B36 management operations, and composes eight-order state with L2. Its
single outer owner spans both stages and the final response. CONFIG/CLEAR clear
both epochs, INVALIDATE propagates to both, and state errors poison L2 trust.
State QUERY/ignored events produce a BBO snapshot without an aggregate delta.

The example preserves separate r_state_status and r_l2_status. If L2 rejects a
pair after order state committed it, the controller explicitly INVALIDATEs order
state before exposing the result. Both fault flags are then set, the retained
L2 quote is untrusted, and the original state mutation remains committed. A
complete snapshot/replay with CONFIG/CLEAR is required for recovery. No rollback
or automatic feed repair is claimed. With default L2_LEVELS8, every reachable
eight-order state fits. L2_LEVELS1..8 is exposed so smaller-capacity failures can
be tested naturally; the finite example TB uses1 and proves both the retained
old quote and the already-committed replacement order after a FULL rejection.
It also checks >32-bit aggregation, C price preservation, same-price U, faulted
retirement, CLEAR/CONFIG recovery and symbol filtering.

The runner first checks all planned source/tool hashes and archives plan.json,
then eleven exact HDL/model/runner/list/dependency inputs before importing the
oracle. It freezes three vectors before the first HDL child. Each of eleven
fixed children has a20-second hard deadline, tree termination and bounded
cleanup; first failure stops later launches and an existing receipt prevents
automatic retry. Actual name/argv/cwd must match the timestamp-substituted plan.
The oracle uses ordinary price dictionaries and max/min, with complete live-RAM
comparisons after every normal command.

The first run `reports/20261106T042737498295Z/results.json` passed all11 children
and four simulations with no failed/timed-out child or retry. Profiles1/TAG1,
7/TAG8 and64/TAG32 completed232/259/373 normal commands, total864:650 APPLY,
113 GET,43 SNAPSHOT,49 CLEAR,3 INVALIDATE and6 invalid opcodes. Every response
field and complete live map was checked, including error preservation. Held
responses occupy5184 clocks;849 real future commands were offered before
retirement and held through eventual acceptance. There are12 live reset probes
plus three initial resets. The actual example checks16 combined results and
one natural aggregate FULL after a committed U, with explicit invalidation.

All eleven current/archived input pairs,22 raw logs,three vectors,four generated
images,two tools and the current/archived plan were verified against hashes.
Source/archive/vector/plan/tool unchanged and exact-plan-executed flags are all
true. Compiler warnings concern inherited/missing timescales only; simulation
stderr is empty. The approved authoring plan retains its original NOT_RUN/
pending-vector metadata as historical input; the first receipt is authoritative
for actual execution and vector hashes. See QUALIFICATION.md, B37_DELIVERY.json
and SOURCES.md for evidence, coverage limits and provenance.

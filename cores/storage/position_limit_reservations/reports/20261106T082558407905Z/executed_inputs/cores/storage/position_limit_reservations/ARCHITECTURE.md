# B42 semantic selection and architecture

Exact baseline:2e7a6fb51f32e525c1026c28d1f2f45e36545ebc.

This adds signed persistent quantity risk and directional ticket lifecycle.
Actual RTL comparisons: `pretrade_credit_ledger` stores unsigned64 limits/used
and whole-ticket holds; RELEASE always removes the entire hold. It has no partial
fill, signed balance or position. Its `credit_gated_ioc16` admits buy limits only,
holds gross price*quantity and releases everything on normal IOC completion even
after fills. `price_level_ioc_matcher` consumes displayed price-level quantities;
its book and ordered dictionary do not track account positions. `itch_order_state`
keeps market order identity and removal/add deltas for one instrument, not actual
account holdings or possible future positions. `trade_correction_ohlcv_state`
repairs tape statistics. Packet scheduler service reservations concern packet
transmission time. Canonical and legacy RTL in cores/components/systems were
searched for position limits, net position, open buy/sell, pretrade, reservation,
holdings and buying power before selection; no matching directional service was
found. This is independent behavior, not another unsigned credit amount width.

Options considered: independently limiting net outstanding quantity incorrectly
lets opposite unfilled orders fund admission. A single unsigned hold cannot
represent long/short positions or partial fills. A fully parallel64-ticket CAM
duplicates64-bit equality and wide selection. An external associative engine adds
another transactional dependency. The chosen linear bounded scan reuses one
synchronous ticket read port and one64-bit comparator, with one context RAM.
No legacy RTL or public interface is changed.

Each context row is `{pad4,position64,min64,max64,buy_open38,sell_open38}` =272bits.
Each ticket row is `{pad3,context4,buy1,remaining32,ticket64}` =104bits.
Payload is `272*CONTEXTS +104*TICKETS`:default5504bits/max11008bits. Configured
and live metadata are40bits default/80bits max; count, scanner, saved request,
working context, RAM response and public result registers are bounded scalar
state. There is no register-array payload or reset sweep. The real example adds
two8-entry64-bit ordered RAM payloads (1024bits) and their count/control registers.
No additional per-slot validity array is needed by those dense dictionaries.
Actual BRAM block packing may waste space; payload bits are not a device estimate.

For64 tickets, each quantity<=2^32-1, a directional total is at most
`64*(2^32-1)=2^38-64`, exactly representable in unsigned38. The pre-capacity
candidate may include a65th quantity, bounded by `65*(2^32-1)<2^39`, hence39bits.
Signed65 endpoints cover the full signed64 position plus/minus any such total:
the interval lies strictly inside [-2^64,2^64-1]. All concatenations explicitly
zero/sign extend before arithmetic and signed comparisons. FILL uses signed65
position +/- unsigned32 and checks sign-extension consistency before committing
64bits. Its directional subtraction is unsigned38, after validating the saved
positive remaining quantity against the context open sum.

When valid, invariants are min<=p<=max, p+B<=max, p-S>=min, positive live ticket
remainders, configured saved contexts, and each directional total equal to the
sum of its live ticket remainders. Reserve establishes the endpoint bounds.
Buy FILL(q) leaves the upper endpoint p+B unchanged and increases the lower
endpoint p-S; sell FILL(q) leaves the lower unchanged and decreases the upper.
Thus any valid partial/full fill preserves both bounds. CANCEL decreases one
directional total without moving p. CONFIG requires both totals0. It cannot
silently change a position under outstanding orders.

All ordinary validation precedes writes. Reserve writes its ticket, then context,
then publishes live metadata only after both RAM responses. Partial FILL writes
the reduced ticket, then context; complete FILL/CANCEL update context before
removing live metadata. One owner hides these intermediate states. A backend
fault can leave private partial writes: sticky invalidation quarantines them and
does not claim rollback. CLEAR/reset metadata starts a new epoch. GETs validate
the addressed context/ticket and return complete snapshots; they are not a full
background ECC or global invariant scrub.

SCAN handles an empty row in one clock and a live row in two clocks (request in
SCAN, synchronous response in T_WAIT). The worst-case scan is2*TICKETS clocks.
Context read and write each take two clocks, ticket write two, with one dispatch
clock. A conservative source-level result-visibility bound is2*TICKETS+10 clocks
after command acceptance, assuming the provided private RAMs; the TB uses
2*TICKETS+16 for scheduling margin. Output stalls remove any unconditional
transaction deadline. The wrapper serializes one reserve, real matcher service,
and up to one fill plus one cancel; forwarded fill stalls also extend ownership.
No MHz, line-rate, PPA or board claim follows from these cycle bounds.

Structural risk MEDIUM:65-bit endpoint add/compare paths, wide272-bit context
packing and serialized multiword accounting need future physical assessment.
There are no multipliers, dividers, DSP requirements, external memory controllers
or vendor hard blocks. Expressions may infer multiple add/subtract/comparison
cones for two endpoint tests; operations are serialized over commands and ticket
rows, not promised to map to one physical ALU. The default/max storage is bounded.

The IOC wrapper preserves a complete reservation during all fills because no
other public owner can observe or admit risk operations in that interval. It
commits one actual aggregate fill only after all real fill transfers retire,
then cancels the residual, and publishes done last. This supplies persistent
position behavior across orders with the unchanged actual book. Post-match
failure requires reconciliation; neither a book rollback nor an exchange-grade
transaction log is claimed.

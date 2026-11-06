# Signed positions with directional order reservations

`position_limit_reservations` retains an actual signed position for each bounded
account-symbol context. Buy and sell open quantities are separate: opposing
unfilled orders never net. A reservation is legal only when both possible
position endpoints remain within the configured signed limits. Partial fills
consume a saved ticket and change the actual position; cancellation removes
only the remaining reservation. Positions survive normal order completion.

Authoring status: **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The finite plan is prepared for independent source review. No numerical
planning, oracle preparation, HDL, synthesis, PnR, STA, board, PPA or inherited
regression was executed during authoring. Subsequent immutable results and
qualification, when present, record the evidence for the frozen sources.

## Numeric domain and configuration

| Parameter | Default | Legal range |
| --- | ---: | --- |
| CONTEXTS | 8 | 1..16, including non-powers of two |
| TICKETS | 32 | 1..64, including non-powers of two |
| TAG_W | 8 | 1..32 |

Unsupported parameters deliberately fail elaboration through a named missing
module. `c_context` is a complete unsigned32 index, checked before narrowing.
The application maps each account-symbol pair to one context; this core does
not decode account or symbol identifiers. Position, minimum and maximum are
full signed64 two's-complement integers. Quantities are full unsigned32 and
must be positive for RESERVE/FILL. Ticket identity is full unsigned64; zero and
all ones are valid. Ticket IDs are globally unique while live and reusable
after complete FILL or CANCEL. There is no implicit scale or rounding.

Let `p` be position and `B/S` the outstanding buy/sell quantities. Admission
checks `p+B <= max_position` and `p-S >= min_position`, including the candidate
quantity in its saved direction. This intentionally covers either direction
filling before the other. It does not replace those checks with a net open
quantity. A buy fill of q makes `(p,B)=(p+q,B-q)`; a sell fill makes
`(p,S)=(p-q,S-q)`. CANCEL leaves p unchanged. Arithmetic uses 65-bit signed
endpoints and a 39-bit candidate open sum before any narrowing or RAM write.

## Clock, ownership and reset

The sole clock is `clk`; `rst_n` is asynchronous active low. Release reset
synchronously to clk. Assertion masks ready/valid/busy, cancels any in-flight
operation or held result, and empties configured/live metadata. Payload RAM is
not reset and cannot be observed without new live/configured metadata. Reset
starts a new epoch without a cancellation response or rollback promise.

There is no CE, CDC, packet/LAST signal or external memory interface. A public
transfer occurs on a rising edge with valid && ready. A source must hold valid
and every field stable while blocked. A response remains stable under arbitrary
backpressure. One accepted command owns the service until its result retires;
there is no same-edge result retirement and command admission. `busy` includes
a held result. The private synchronous RAMs use clk_en=1 and their native
request/response handshake. Private reads and writes are completely drained.

## Commands and results

All commands use `c_op[2:0]` and `c_tag[TAG_W-1:0]`.

| Op | Command | Other significant fields |
| --- | --- | --- |
| 0 | CONFIG | context, position, min_position, max_position |
| 1 | RESERVE | context, ticket, buy, quantity |
| 2 | FILL | ticket, quantity |
| 3 | CANCEL | ticket |
| 4 | GET_CONTEXT | context |
| 5 | GET_TICKET | ticket |
| 6 | CLEAR | none |
| 7 | INVALIDATE | none |

CONFIG initializes a context or explicitly reconciles its position/limits only
when it has no outstanding quantities in either direction. It requires
`min_position <= position <= max_position`; it cannot erase live reservations.
There is no separate limit-update operation while orders are live. FILL/CANCEL/
GET_TICKET ignore the supplied context, direction and limits: the saved ticket
defines context/direction. FILL cannot exceed the saved remainder. A complete
fill deletes the ticket; another FILL/CANCEL then returns NOT_FOUND.

`r_op/r_tag` echo the request. `r_live[31:0]` always reports the post-command live
ticket count, including on ordinary errors. Successful CONFIG/GET_CONTEXT return
context, position, both limits and both open totals, with ticket/buy/remaining0.
Successful RESERVE/FILL/CANCEL/GET_TICKET additionally return the saved ticket and
direction. `r_remaining` is its post-command remainder: requested quantity for
RESERVE, reduced quantity for FILL, zero for CANCEL, saved quantity for GET_TICKET.
All context/ticket/position/limit/open/remaining fields are zero on any error and
on CLEAR/INVALIDATE. They have no snapshot meaning when r_valid=0.

| Status | Value | Meaning |
| --- | ---: | --- |
| OK | 0 | Command completed |
| BAD_CONTEXT | 1 | Complete unsigned32 context is outside CONTEXTS |
| NOT_CONFIGURED | 2 | Context is not configured in this epoch |
| BAD_QUANTITY | 3 | RESERVE/FILL quantity is zero |
| DUPLICATE | 4 | Ticket is already globally live |
| LIMIT_EXCEEDED | 5 | Either exact candidate endpoint exceeds its limit |
| FULL | 6 | No ticket row after otherwise legal admission |
| NOT_FOUND | 7 | Missing FILL/CANCEL/GET_TICKET ticket |
| BAD_LIMITS | 8 | CONFIG position is outside its supplied limits |
| INVALID_STATE | 9 | Epoch is invalid |
| OPEN_RESERVATIONS | 10 | CONFIG would reconcile a context with open orders |
| BACKEND_FAULT | 11 | Unexpected private RAM/accounting inconsistency |
| EXCESS_FILL | 12 | FILL quantity exceeds the saved remainder |

CLEAR and INVALIDATE succeed before all ordinary checks. Otherwise INVALID_STATE
dominates. FILL quantity0 precedes ticket lookup. Context-based operations check
the complete index, then RESERVE quantity0 or CONFIG bounds, then configuration.
For a valid positive RESERVE, global DUPLICATE precedes LIMIT_EXCEEDED, then FULL.
For an existing ticket, backend consistency precedes EXCESS_FILL. Ordinary
statuses1..10 and12 preserve private payload and metadata; status9 also preserves
the already invalid epoch. BACKEND_FAULT sets sticky `faulted`; normal operations
then return INVALID_STATE. INVALIDATE preserves private state and live count.
CLEAR empties everything and requires fresh CONFIG. There is no automatic repair,
hardware timeout, journal, retry or rollback after a private backend fault.

## Real IOC composition

`example/position_gated_ioc8.sv` instantiates the default risk core and the
unchanged `price_level_ioc_matcher` at LEVELS8, including its real book and two
ordered RAM dictionaries. It supports both buy and sell **limit** IOC with full
price32/quantity32, including price0. Admin (`c/r`) has priority over matcher
maintenance (`q/qr`), then IOC (`i`). Each owns the wrapper through public result
retirement; admin/maintenance cannot interleave with an IOC or held fill/done.

An IOC first reserves its complete requested quantity. Rejection never submits
it to the matcher. On success the wrapper forwards the real matcher's fills
with backpressure, keeping the complete reservation and old position while the
IOC owns the wrapper. It checks retired fill quantity/direction/index/tag against
the final matcher totals. After a normal completion, it issues one FILL for the
actual filled quantity (skipping zero), then CANCEL for any remainder (skipping
a complete fill). Public done appears only after the risk responses retire.
The persistent position now affects the next IOC. External admin reservations
participate in the same directional totals and global ticket namespace.

`d_stage` is0 for normal committed risk accounting,1 for pre-match rejection,
2 for internal isolation. `d_risk_status` is the failing risk response, otherwise0;
an identity/protocol fault may isolate with status0. `d_reason` and fill/remaining/
level counts are the real matcher result after admission (reasons0 full,1 empty,
2 outside limit,3 bad quantity,4 backend). Pre-match rejection returns reason and
level/fill counts0, and the original requested remainder. `d_context/d_ticket/
d_tag` identify the IOC. Position/open fields are a post-accounting snapshot only
for stage0; they are zero for stages1/2.

A matcher backend/protocol failure causes INVALIDATE before public done, retaining
the complete risk reservation and old risk position. A failed post-match risk
response also causes INVALIDATE before done. Prior book mutations and retired
fills remain; a risk update may already have committed or partially written.
Those private values cannot be used until CLEAR and explicit reconciliation.
CLEAR resets risk only and leaves the matcher book intact. Reset empties both.
This is a bounded quantity-risk service, with no cash, price/notional margin,
fees, settlement, PnL, replace protocol, persistence or complete exchange system.

## Offline closure and finite checks

Run from this package root; `files.f` and `example/files.f` list all RTL sources.
There are no includes, initialization files, vendor primitives, generators or
network runtime dependencies. `SOURCES.md` records fixed external comparisons.

The independent model uses unbounded Python integers and recomputes open totals
from ticket dictionaries. Three deterministic parameter profiles (1/1/1,
3/5/8,16/64/32 for contexts/tickets/tag) cover signed64 extremes, a full38-bit
aggregate, both directions without netting, partial fill/cancel, expected failure
state preservation, high public indices and ticket IDs, capacity/duplicate
priority, snapshots, held responses, real future GET_CONTEXT offers and five
live reset phases. Every normal response and complete live/configured contents
are checked. The fixed example includes two fault injections after real retired
fills and two live reset cancellations. Fault injection is testbench-only.

`python -B run_checks.py --write-plan` only hashes source/tools and writes the
finite plan; it never imports/calls the oracle or invokes HDL. Execution requires
independent C/root review, the exact frozen plan, and a separate root run gate.
The runner then creates durable INCOMPLETE evidence, archives all executable
inputs/dependencies plus the plan, makes exactly three oracle calls, freezes all
vectors, and runs exactly eleven HDL children: three syntax checks and four
compile/simulation pairs. Each child has20 seconds, process-tree termination5
seconds and output drain2 seconds. First failure stops; any started report blocks
automatic rerun. Raw streams, exact argv/cwd, tools, archives, vectors and images
are SHA256 recorded; failed logs/images are retained. All files are byte-preserved
by `.gitattributes`; archived attributes are renamed `.gitattributes.executed.txt`.

See `ARCHITECTURE.md` for the structural/numeric proof. Verification and physical
performance must be judged from actual later evidence, not from this plan.

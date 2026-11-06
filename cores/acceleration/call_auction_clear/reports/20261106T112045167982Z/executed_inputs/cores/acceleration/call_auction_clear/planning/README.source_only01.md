# Bounded limit-only call-auction indication

`call_auction_clear` computes an indicative uniform clearing price, maximum
executable quantity and signed imbalance from an unsorted finite snapshot of
aggregated bid/ask levels. It adds an independent capability beyond the existing
continuous IOC matcher, BBO consolidation and persistent L2 quantity service.
`example/call_auction_book.sv` locks and reads an actual unchanged
`price_level_order_book`; it does not replace the backend or consume liquidity.

This is a documented deterministic **limit-only** policy. It has no market
orders, per-order allocation/time priority, collars, hidden orders, venue
session state, feed decoder, currency scaling or exchange certification.

## Mathematics and numerical domain

Candidate prices are exactly the prices appearing in the snapshot. Duplicate
prices and repeated same-side records are allowed; their quantities add. For a
candidate price p, B is the sum of bid quantities at price>=p, S the sum of ask
quantities at price<=p, and V=min(B,S). A positive-volume candidate is eligible
only when all strictly higher bids and all strictly lower asks can each fill
within V. Among eligible candidates select, in order:

1. Largest V.
2. Smallest abs(B-S).
3. Smallest unsigned tick distance to the request's reference price.
4. Lowest price.

No eligible positive volume produces NO_CROSS, with all numerical result fields
zero. The policy considers submitted limit prices, including price0 and the
maximum price; it does not choose an unsubmitted midpoint or clamp a reference
inside a price interval. It publishes indication only, with no allocation or
book mutation. Prices and quantities are exact unsigned integer ticks/lots.

Core parameters: MAX_ROWS=1..64 (default32); PRICE_W/QTY_W/TAG_W=1..32
(default32/32/8). SUM_W is fixed to QTY_W+clog2(MAX_ROWS+1); overriding it to a
different value is illegal. Every side sum is at most MAX_ROWS*(2^QTY_W-1),
so this width includes the full legal input domain. m_imbalance is signed
SUM_W+1 bits and is exactly B-S, positive for excess buy quantity. No multiply,
divide, rounding, saturation or wrapping is used. Unsupported parameters
instantiate a named missing module.

## Core interface and ownership

One rising-edge clock, active-low asynchronous rst_n; release reset synchronously.
Ordinary valid/ready, no CE or CDC. A transfer occurs only when both valid and
ready are high. A blocked source holds its entire payload. There is no same-edge
response retirement/header admission fallthrough.

| Channel | Fields and meaning |
| --- | --- |
| a_valid/a_ready | Snapshot header: a_rows[31:0], a_reference[PRICE_W-1:0], a_tag[TAG_W-1:0] |
| s_valid/s_ready | Exactly a_rows records after a legal nonempty header: s_side (0 bid,1 ask), s_price[PRICE_W-1:0], s_quantity[QTY_W-1:0] |
| m_valid/m_ready | One result: m_status[1:0], echoed m_rows[31:0]/m_tag, m_price[PRICE_W-1:0], m_matched/m_buy/m_sell[SUM_W-1:0], signed m_imbalance[SUM_W:0] |

Status0 CLEAR means positive matched quantity;1 NO_CROSS includes an empty
snapshot;2 BAD_COUNT means a_rows>MAX_ROWS;3 BAD_QUANTITY means at least one
accepted record has quantity0. A zero-length or bad-count header consumes no
records and immediately creates one response. A legal positive count always
consumes all its declared records, including after an early zero quantity,
before returning BAD_QUANTITY. These records cannot bleed into the next header.
There is no implicit EOF, record timeout or transport recovery. The source must
eventually supply the advertised records, or assert reset to cancel ownership.

Header admission excludes every other header until its result retires. All
result fields remain stable under unlimited output backpressure; fields outside
m_valid are unspecified. Reset immediately masks all ready/valid, cancels partial
loading/computation/held results and invalidates all row storage. RAM contents
are not reset: the next snapshot overwrites every row that can be read.

For N>0 valid positive records with no input stalls, the first result is visible
2*N*N+4*N+1 cycles after header acceptance (7 cycles at N=1,8449 at N=64).
After the final record this is 2*N*N+3*N+1 cycles. Output stalls extend retirement
without changing the calculation. Unlimited input or output stalls remove any
whole-transaction deadline. Every candidate is evaluated, including duplicates;
the interface does not claim one snapshot per clock.

## Actual persistent-book composition

`call_auction_book` has LEVELS=1..32 (default8) per side, the same price/quantity/tag
width limits, and fixed SUM_W=QTY_W+clog2(2*LEVELS+1). It exposes the complete
existing c_/r_ maintenance API (ops0 SET,1 ADD,2 SUB,3 DELETE,4 BEST,5 DEPTH,
6 CLEAR_SIDE,7 CLEAR_ALL;8..15 BAD_OP), including its exact errors and counts.
See the existing book README for the unchanged operation contract. The new a_
header contains only reference/tag; the composition discovers row count itself.
Its m_ result adds frozen m_bid_levels/m_ask_levels[31:0] to the core fields.

When both public requests are valid in idle, auction has priority. One owner
spans a maintenance command through its public reply retirement, or an auction
through its public result retirement. The latter first obtains side counts with
a read-only BEST, then queries every bid and ask DEPTH rank below its frozen
count. Each returned positive row transfers directly into the core. No maintain
command can change the book during this walk, computation or held result. The
backend's own contract therefore guarantees every private DEPTH is found/OK.
An empty or one-sided book is a valid no-cross indication. Counts refer to the
same locked book used by the computation. Back-to-back auctions with different
reference prices are read-only and can produce different tie-break choices.

Common reset cancels both controllers and **empties both persistent book sides**,
including a committed mutation whose reply was held. Reset is cancellation and
logical emptying, not transaction rollback. No external memory port or runtime
configuration is introduced. The normal ready/valid interfaces are not direct
connections for CE-qualified streams.

## Closure and status

Both files.f lists resolve from this package directory. The core has no RTL
dependency. The actual composition reuses unchanged canonical dictionary and
RAM dependencies at their existing paths. All closure bytes are pinned by
SOURCE_SEAL.json and FINITE_PLAN.json; no external checkout is needed offline.

Current state is RTL_CANDIDATE and HW_UNVERIFIED. No model, preparation, HDL,
runner, synthesis, PnR, STA, board or PPA execution has occurred for this source.
The immutable finite plan requests one archived preparation (one local oracle
import),3 syntax children and5 compile/simulation pairs. Its three core profiles
span N1/9/64 and two actual-book profiles span L1/8, including one-bit and full
32-bit fields. Independent vector totals and explicit runtime counters are
separate domains. The TB also checks held outputs, genuinely pending next
requests, reset cancellation/recovery and auction-priority isolation.

Only after root and an independent peer complete source review may root create
SOURCE_REVIEW.json with the plan/seal hashes and explicit_unique_execution_gate
true. The fixed entry is Python312 -I -B run_checks.py --execute. The exclusive
.git/anscore-b44-call-auction-once.json guard permits one attempt. Every child
has20 seconds, at most5 seconds for tree termination and2 seconds for pipe drain;
any failure stops subsequent children and retains all evidence. No automatic
retry, cleanup or inherited regression is included. The runner compiles archived
source copies and records exact source/tool/vector/argv/raw/image evidence.

ARCHITECTURE.md records structural resource/latency risks. SOURCES.md and
EXTERNAL_SOURCE_REVIEW.json record semantic deduplication and read-only external
source/license inspection. No unrun check is PASS.

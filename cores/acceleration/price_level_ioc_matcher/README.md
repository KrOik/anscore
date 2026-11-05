# L2 price-level immediate-or-cancel matcher

Original bounded IOC controller over the unchanged two-sided `price_level_order_book`.
It accepts a buy/sell taker, walks the opposite best prices, subtracts liquidity,
and emits one fill per consumed price level. Unfilled quantity is cancelled.
The separate maintenance port seeds, updates and inspects persistent liquidity.
This is an aggregated L2 primitive: individual order IDs, FIFO/time priority,
resting takers, self-trade prevention, risk, fees, notional and exchange protocol
handling belong in other blocks. Integer price and lot units are application-defined.

## Interface and numerical behavior

One rising-edge clock, active-low asynchronous `rst_n`, ordinary valid/ready,
no clock enable. All inputs must remain stable while valid and not ready.
Every output payload is held unchanged while its valid is high and ready low;
payload outside valid is unspecified. All widths are unsigned. Parameters
`LEVELS=16`, `PRICE_W=32`, `QTY_W=32`, `TAG_W=8`; legal levels1..32 and widths1..32.
Illegal parameters instantiate a named missing module. There is no CDC.

| Ports | Meaning |
|---|---|
| `c_valid/c_ready` | Maintenance command acceptance |
| `c_op[3:0]` | 0 SET,1 ADD,2 SUB,3 DELETE,4 BEST,5 DEPTH,6 CLEAR_SIDE,7 CLEAR_ALL;8..15 BAD_OP |
| `c_side` | 0 bid (highest first),1 ask (lowest first) |
| `c_price/c_quantity` | PRICE_W/QTY_W integer level price/lot quantity |
| `c_rank[31:0]` | Zero-based depth rank; ignored outside DEPTH |
| `c_tag[TAG_W-1:0]` | Opaque maintenance correlation tag |
| `r_valid/r_ready` | One maintenance reply per accepted command |
| `r_op/r_side/r_tag` | Echoes of maintenance command |
| `r_status[2:0]` | 0 OK,1 NOT_FOUND,2 FULL,3 BAD_QUANTITY,4 OVERFLOW,5 UNDERFLOW,6 BAD_RANK,7 BAD_OP |
| `r_found` | Existing-on-entry for SET/ADD/SUB/DELETE; found row for BEST/DEPTH;0 on errors/clear |
| `r_price/r_quantity/r_previous` | Successful price, post-state quantity, pre-state quantity; BEST/DEPTH previous0; errors/clear all0 |
| `r_bid_levels/r_ask_levels[31:0]` | Counts after maintenance operation, valid with reply |
| `i_valid/i_ready` | IOC command acceptance |
| `i_buy/i_market` | Buy consumes asks, sell consumes bids; market bypasses limit comparison |
| `i_limit[PRICE_W-1:0]` | Buy accepts price<=limit; sell accepts price>=limit, inclusively |
| `i_quantity[QTY_W-1:0]` | Requested lots; zero returns BAD_QUANTITY without touching the book |
| `i_tag[TAG_W-1:0]` | Copied to every fill and final completion |
| `f_valid/f_ready` | Ordered fill stream, one fill per price level |
| `f_buy/f_price/f_quantity` | Direction, execution level and strictly positive executed lots |
| `f_remaining/f_index[31:0]/f_tag` | Remaining lots after this fill; zero-based fill index; IOC tag |
| `d_valid/d_ready` | Exactly one final completion, after all its fills retire |
| `d_reason[2:0]` | 0 fully filled,1 opposite book empty,2 next price outside limit,3 bad quantity,4 unexpected backend reply |
| `d_filled/d_remaining[QTY_W-1:0]` | Executed and cancelled lots; sum equals original request in ordinary operation |
| `d_fills[31:0]` | Number of emitted fills, bounded by LEVELS |
| `d_bid_levels/d_ask_levels[31:0]/d_tag` | Counts after final mutation or check, and IOC tag |

`f_remaining` is QTY_W bits; only `f_index` is32 bits. Prices0 and all ones
are ordinary prices, and market behavior uses its explicit flag. No rounding,
division, notional multiply or signed overflow is involved. A partial fill leaves
the level with its positive residual. Exact depletion deletes it. Each IOC uses
at most LEVELS fills; summing fills fits QTY_W because it never exceeds the request.
The limit is checked before each mutation. There is no fill LAST bit: the held
completion gives the transaction boundary, including empty/zero-fill transactions.

Maintenance mirrors the underlying book: SET replaces, ADD checks overflow,
SUB rejects underflow and deletes exact zero, DELETE removes an entire level.
Zero SET/ADD/SUB is BAD_QUANTITY. Each side has its own LEVELS capacity; replacement
while full succeeds. DEPTH rank>=LEVELS is BAD_RANK, an absent legal rank is
NOT_FOUND. All error commands leave liquidity unchanged. CLEAR_ALL clears both
sides regardless of c_side. Counts are cached from every actual backend reply.

## Ownership, timing and reset

Maintenance has priority when both input valid signals are high at idle; IOC
ready is then low. One transaction owns the complete block from input handshake
through its maintenance reply or IOC completion handshake. Both input readies
stay low during ownership, including stalled fills and completions. The next
transaction may be accepted on the clock following retirement, never on the
retirement edge itself. Independent streams must arbitrate upstream if starvation
under a continuously offered maintenance stream is unacceptable.

The controller latches maintenance then sends it on the next clock. IOC quantity0
raises completion immediately after the acceptance edge. A nonzero IOC sends
BEST on the following clock, waits for its response, sends SUB on the following
clock, and waits for its response. A confirmed SUB raises fill immediately after
the response-capture edge. The book's variable synchronous-RAM search/shift
latency dominates. No new BEST starts until the current fill handshake. Following
the last required fill handshake, a zero remaining quantity raises completion;
otherwise another BEST determines empty or limit stop. These sequential states
define exact data order; there is no fixed cycles-per-order or continuous
one-fill-per-clock claim. Book RAM initialization must finish before either
input ready is asserted after reset.

The book subtraction commits **before** a fill is published. A stalled fill
therefore already consumed liquidity, and no command can observe it until the
transaction retires. Reason4 detects inconsistent internal replies; it does not
roll back an already committed mutation and is not externally fault-injected
in the finite tests. No external memory access or retry interface exists.

Reset assertion masks all readies/valids immediately, cancels held outputs and
empties both books, including liquidity from earlier completed commands. RAM
contents are invalidated logically, not reset bit by bit. Reset is a new book
epoch; it provides neither transaction rollback nor replay. A receiver discards
an IOC prefix lacking completion across reset. Deassertion must meet clock
recovery/removal requirements; the core does not synchronize reset.

## Architecture, dependencies and example

One original small FSM composes one unchanged book, which composes two unchanged
ordered dictionaries and their unchanged synchronous single-port RAM. Every
production dependency appears once at its canonical path in `files.f`; both
file lists resolve from **this package directory**. Dependencies are entirely
in this repository and require no network, ROM generation or vendor primitives.

Default packed row storage is2×16×64=2048 bits; maximum2×32×64=4096 bits, plus
child RAM request/reply buffers and scalar control. Different widths pad rows
to bytes. No new array, CAM, sorting network, DSP or multiplier is introduced.
Binary search and sequential row shifts trade latency for bounded storage;
worst fills each incur lookup and potentially O(LEVELS) deletion shifts.
Architecture risk is MEDIUM for variable latency, sustained output stalls and
two backends; these are source-level estimates, not area/timing measurements.

`example/quote_ioc16.sv` turns absolute quantity quotes into SET/DELETE maintenance
commands and connects a real16-level matching composition. A quote quantity0
deletes, including NOT_FOUND on a missing level. The quote response must be
consumed before a sweep can start. The example exposes the fill/completion
streams and reports their tags and counts; its finite simulation seeds an ask,
partially satisfies a larger buy, stalls outputs, and checks cancelled remainder.

Run `python run_checks.py` only for the documented finite source checks. It
archives exact HDL, lists, runner and vectors before invoking Icarus, gives each
child20 seconds, saves raw logs/hashes, and stops the plan at its first failure.
It launches no synthesis, PnR, STA, board test or inherited regression. The
checked delivery receipt records actual coverage and maturity; all hardware
properties remain HW_UNVERIFIED.

The single run `reports/20261105T183519445704Z/results.json` has11 PASS children:
three syntax checks, three parameter-profile compile/sim pairs, and the actual
example compile/sim pair. Profiles `(LEVELS,PRICE_W,QTY_W,TAG_W)` are `(1,1,1,1)`,
`(3,8,8,8)` and `(32,32,32,32)`. They check715 modelled maintenance responses,
130 IOC completions and128 ordinary fills, three simultaneous-input priority
flows and12 reset scenarios. The example checks one additional fill. Every
ordinary response/fill is held under deterministic backpressure. Coverage
includes both sides, empty/full capacity, limit equality and rejection, market
sweeps, residual levels, exact deletion, maximum widths, invalid commands,
same-side preservation, live-input mutation after acceptance, and reset during
work/held fill/held completion/held maintenance. The independent oracle uses
ordinary dictionaries and sorted price keys. No failed, timed-out or retried
HDL check occurred. These finite results earn LINT_PASS, UNIT_SIM_PASS and
INTEGRATION_CANDIDATE alongside HW_UNVERIFIED; they do not exhaust the input
domain. `B35_DELIVERY.json` seals the exact checked source/dependency bytes.

Source-only cross-review found no blocking functional issue. One coverage limit:
the TB's dummy offers during ownership are adversarial cancelled offers. They
check that ready stays low and held outputs remain stable; they do not qualify
a legal future transaction continuously offered until eventual acceptance.
Ordinary accepted commands and simultaneous-input priority are checked separately.

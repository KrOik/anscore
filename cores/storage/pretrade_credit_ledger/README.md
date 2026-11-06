# Transactional pretrade credit ledger

`pretrade_credit_ledger` maintains bounded account limits and globally unique
ticket holds. A successful RESERVE adds a positive amount to exactly one account;
RELEASE removes the complete amount saved with that ticket. Failed ordinary
commands preserve the account and ticket state. One command owns the service
through its response retirement, including the private multi-RAM update.

Current status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE /
HW_UNVERIFIED**. The first reviewed finite run passed all11 children and4
simulations, without failure or retry. No synthesis, PnR, STA, board work,
PPA measurement or inherited regression was run.

The immutable receipt is
[`reports/20261106T051649087866Z/results.json`](reports/20261106T051649087866Z/results.json),
SHA256 `d72423fc72a947dbd5462f0ee1950d0459bae4abdca086623c220f7d86898fc0`.
`QUALIFICATION.json` records an independent post-run source/archive/vector-record,
raw-log, marker, coverage, tool, argv and temporary-image hash audit without
importing the runner/oracle or invoking HDL again. The core profiles completed
944 commands,5664 held cycles,926 real future offers and15 live resets plus3
initial resets. The actual example completed15 admin commands,12 maintenance
commands,16 IOC offers and6 retired fills, with161 held cycles,3 resets and21
cycles of an actual blocked future admin offer. Compile logs contain only missing
RTL timeunit/timeprecision warnings; no numeric or port-width warning was emitted.

## Numeric domain and parameters

| Parameter | Default | Legal |
| --- | ---: | --- |
| ACCOUNTS | 16 | 1..16, including non-powers of two |
| TICKETS | 32 | 1..64, including non-powers of two |
| TAG_W | 8 | 1..32 |

Unsupported values fail elaboration through a named missing module. Account
input is a complete unsigned16 index and is checked before narrowing. Tickets,
limits, used amounts and reserve amounts are full unsigned64 integers. Zero and
all-ones ticket IDs are valid. Limits may be zero; reserve amount must be positive.
The application chooses a single common credit unit. There is no implicit scale,
signed balance, currency, interest, refill, rounding or partial release. Reserve
uses a 65-bit addition and rejects excess credit before any write.

## Ownership, clock and reset

The sole clock is `clk`. `rst_n` is asynchronous active low; release it
synchronously to clk. Assertion masks ready/valid, cancels in-flight operations
and held results, and empties all configured/live metadata. RAM payload is not
reset, cannot become visible without a new write, and needs no initialization
sweep. Reset cancels the old epoch without a cancellation result or rollback.

There is no CE or CDC. Public transfers occur on rising edges with valid && ready.
Sources keep valid and every field stable while blocked; response valid and all
fields remain stable under arbitrary backpressure. One command is owned until its
result transfers. There is no same-edge result retirement/new-command admission,
stream LAST, packet boundary or external memory interface. `busy` is high while a
command/result is owned, and is masked during reset. The private RAM CE is tied1.

Commands use `c_op[2:0]`, `c_account[15:0]`, `c_ticket[63:0]`,
`c_amount[63:0]`, `c_limit[63:0]` and `c_tag[TAG_W-1:0]`.

| Op | Meaning | Fields used beyond op/tag |
| --- | --- | --- |
| 0 CONFIG | Configure/reconfigure account; keep existing used | account,limit |
| 1 RESERVE | Atomically create a new ticket hold | account,ticket,amount |
| 2 RELEASE | Remove the saved ticket and subtract its saved amount | ticket |
| 3 GET_ACCOUNT | Observe one configured account | account |
| 4 GET_TICKET | Observe a saved ticket plus its current account totals | ticket |
| 5 CLEAR | Empty all configuration/tickets and clear faulted | none |
| 6 INVALIDATE | Mark epoch invalid, preserving private data | none |
| 7 Undefined | BAD_OP | none |

CONFIG may lower a limit only to a value at least equal to used; it cannot
silently erase holds. RESERVE rejects an existing ticket even when another
configured account is supplied. RELEASE ignores the supplied account/amount/limit;
the saved account and full saved amount determine its effect. A second release
returns NOT_FOUND. At capacity, releases and observations continue to work.

`faulted` indicates an invalid credit epoch. Normal commands, including GET and
CONFIG, then return INVALID_STATE. CLEAR and INVALIDATE still complete; CLEAR
requires the caller to configure accounts afresh. An internal RAM error or
accounting inconsistency returns BACKEND_FAULT and sets faulted. This guard does
not promise recovery of any private partial write. There is no hardware timeout,
automatic repair, persistent journal or transaction rollback.

## Results and failure priority

Every accepted command has one result unless reset cancels it. `r_op/r_tag` echo
the request. `r_live[31:0]` reports the post-command live ticket count even on
errors. CONFIG/GET_ACCOUNT success reports `r_account/r_limit/r_used/r_available`
and ticket/amount0. RESERVE/RELEASE/GET_TICKET success additionally reports the
saved `r_ticket/r_amount`; totals are the post-command account values. CLEAR,
INVALIDATE and every error return all account/ticket/amount/limit/used/available
fields0. Successful CLEAR reports live0; successful INVALIDATE preserves live.
These data fields have no snapshot meaning when r_valid=0.

| Status | Value | Meaning |
| --- | ---: | --- |
| OK | 0 | Operation completed |
| BAD_ACCOUNT | 1 | Complete account16 is outside ACCOUNTS |
| NOT_CONFIGURED | 2 | Account has no limit in this epoch |
| BAD_AMOUNT | 3 | Reserve amount0 |
| DUPLICATE | 4 | Global ticket already live |
| LIMIT_EXCEEDED | 5 | Unbounded used+amount exceeds limit, including 64-bit carry |
| FULL | 6 | No free ticket row after a credit-legal reserve |
| NOT_FOUND | 7 | Missing RELEASE/GET_TICKET ticket |
| BAD_LIMIT | 8 | Reconfiguration would put limit below used |
| INVALID_STATE | 9 | Credit epoch is invalid |
| BAD_OP | 10 | Undefined opcode7 |
| BACKEND_FAULT | 11 | Unexpected private RAM/accounting failure |

CLEAR/INVALIDATE succeed before the fault check; undefined op is BAD_OP even when
invalid. Otherwise INVALID_STATE dominates all ordinary argument checks. For
account operations, BAD_ACCOUNT precedes BAD_AMOUNT, then NOT_CONFIGURED. For a
configured, positive reserve, DUPLICATE precedes LIMIT_EXCEEDED, which precedes
FULL. RELEASE/GET_TICKET ignore all arguments except ticket. Ordinary statuses
1..8 and10 preserve state and do not themselves set faulted.

## Actual IOC combination

`example/credit_gated_ioc16.sv` instantiates this default ledger and the committed,
unchanged `price_level_ioc_matcher`. It accepts only buy limit orders, using
unsigned32 price and quantity with exact unsigned64 `limit*quantity` as an
**in-flight gross notional hold**. Quantity0 or zero notional is rejected by the
ledger before reaching the matcher. Fees and settlement balances are outside
the example; this hold is released in full on normal IOC completion even when
fills occurred. Executed notional is not retained as a cash debit or position.

External ledger management (`c/r`) has priority over matcher maintenance (`q/qr`),
then IOC (`i`). Each owns the wrapper until its result retires. The wrapper captures
all IOC fields before reserving. It submits an IOC only after a successful
reserve, then forwards actual fills under backpressure. The matcher mutates the
book before publishing each fill. Its final completion follows all retired fills.
Only then does the wrapper release the saved ticket, wait for that response and
publish `d_valid`. No maintenance/admin operation can interleave with this owner.

`d_stage` is0 normal IOC with successful credit release,1 credit rejection before
IOC admission,2 internal fault. `d_credit_status` is the failed reserve/release
status or0. `d_reason` is the unchanged matcher reason on admitted IOC orders:
0 fully filled,1 empty,2 outside limit,3 bad quantity,4 unexpected backend.
For credit rejection, reason/counts are0, remaining is the requested quantity,
and filled/fills0. `d_account/d_ticket/d_tag` identify the admitted public request.
`d_used` is the successful release's post-account used, otherwise0; zero here is
not a recovery snapshot on error. `faulted` exposes the ledger state.

Matcher reason4 causes INVALIDATE without RELEASE; a failed release also causes
INVALIDATE. The wrapper drains these private responses before publishing fault
done. The full hold is conservatively retained on matcher failure. Prior book
mutations and retired fills remain. CLEAR starts a fresh credit epoch but leaves
the book intact; reset empties both. This composition does not implement market
orders, sells, fees, positions, settlement, audit persistence, rollback or a full
exchange risk system. Public management may itself reserve tickets; those holds
participate in the same account totals and global duplicate/capacity checks.

## Offline closure and finite checks

Paths in `files.f` and `example/files.f` resolve from this package root. The core
needs only its RTL and canonical shared RAM. The example additionally lists the
existing ordered dictionary, price-level book and IOC matcher. There are no
includes, ROM images, external generators, vendor primitives or network runtime
dependencies. The whole repository source closure remains available offline.

`reference_model.py` uses independent Python dictionaries and unbounded integer
arithmetic, with no RTL imports or Icarus response sampling. The core TB checks
every response and complete configured account/live ticket contents after each
command, holds every response for six cycles, offers real next commands while
blocked, and cancels five live phases by reset. The example TB uses fixed,
hand-derived quote/order/fill results, stalls the final fill, carries a real
future admin offer through IOC completion, checks the full32x32 product, and
injects an unexpected matcher backend status after a real retired fill. This
fault injection tests the invalidation boundary; it is not ordinary market data.

`python -B run_checks.py --write-plan` only hashes sources/tools and writes the
finite matrix; it never imports or calls the oracle and never invokes HDL.
After root source/plan approval, `--execute-approved-plan` requires
`source_review=NO_BLOCKER_ROOT`. It creates durable INCOMPLETE evidence, archives
all executable inputs/dependencies and the plan, generates each oracle profile
once, freezes vectors, then runs exactly11 children. It uses absolute repository
OSS-suite Icarus/vvp,20 seconds per child, bounded tree termination and drain,
raw logs/SHA256, per-child checkpoints and first-failure stop. Any started report
entry blocks reruns. No successful profile is automatically rerun or repaired.

See [ARCHITECTURE.md](ARCHITECTURE.md) for storage/latency/risk budgets and
[SOURCES.md](SOURCES.md) for semantic dedup, pinned reference and dependency hashes.

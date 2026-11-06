# Bounded pretrade credit holds

Baseline: `816d461b12fd402f6a146ca74c7491c7afbd3091` (B38).

The independent capability is exact account-wide reservation by globally unique
64-bit ticket, followed by a keyed complete release using the stored account
and amount. Existing allocators own address units, token shapers replenish and
consume flow tokens, and port credit arbiters schedule grants. Existing order
books and IOC matching do not maintain account limits or ticket hold lifetimes.
Atomic scratchpad operations do not couple multiple records into this service.

Two unchanged `cip_sync_sp_ram` instances hold account `{limit64,used64}` and
ticket `{account8,amount64,ticket64}` rows. Small configured/live bitmaps control
visibility; payload RAM is never reset. A complete ticket comparison scans a
bounded number of live rows sequentially. The first free index is remembered.
One public command owner spans all preflight reads, private writes and response
retirement. There is no second command between the ticket/account updates.

A hash-plus-record design was considered: the existing hash value is limited
to 64 bits, so an account-plus-amount record needs another RAM, a ticket-to-slot
map and slot allocation. At this deliberately small capacity, a direct RAM scan
has similar payload volume and substantially fewer coupled structures. It trades
lookup latency for simple ownership and complete-width comparisons. No new CAM,
parallel ticket comparator bank, hash, allocator, FIFO or shared RTL is added.

Limits, positive amounts and used values are unsigned64. The reserve sum is
unsigned65, compared against a zero-extended limit before taking its low64 bits.
Release checks stored amount against account used before subtracting. No wrapping,
rounding, saturation, floating point, fees or currency conversion is performed.
Public account16 is validated before narrowing to an address; all ticket64 bits
are data, including zero and all ones. Reconfiguration never erases used credit.

| Storage | Default A16/K32 | Maximum A16/K64 |
| --- | ---: | ---: |
| Account row bits | 2048 | 2048 |
| Ticket row bits | 4352 | 8704 |
| Total payload RAM bits | 6400 | 10752 |
| Configured/live visibility bits | 48 | 80 |

Additional scalar registers hold command/result fields, one account snapshot,
one computed used value, indices and count. Both memories have one synchronous
request address and one response slot, tied `clk_en=1`. Separate issue/wait states
consume each response exactly once. Arithmetic and scans are time shared.
No multiplier or divider exists in the core. The actual IOC example adds one
32-by-32 exact notional multiplier and the unchanged matcher/book/dictionary RAMs.

For a command accepted at edge E, a RAM request at E+1 returns for control use
at E+2. Configuring a new account and GET_ACCOUNT expose response valid after
E+2; reconfiguring an existing account takes four edges. Scanning a dead ticket
takes one edge; a live ticket takes three. A successful worst-case reserve has
first valid no later than E+(3*K+7), earliest response transfer E+(3*K+8).
GET_TICKET and RELEASE are bounded by E+(3*K+2) and E+(3*K+4), respectively.
Missing lookup is bounded by E+(3*K+1). These are RTL service-cycle budgets with
the private RAM always enabled. The next public command cannot transfer on the
response-retirement edge. Unlimited output stalls remove a whole-transaction
completion bound. No clock frequency or market-data line rate is promised.

CLEAR/reset discard configured/live metadata and invalidate the entire previous
hold epoch. INVALIDATE preserves private metadata but denies normal operations
until CLEAR/reset. An unexpected RAM error or checked internal accounting
invariant sets this same invalid state and returns BACKEND_FAULT. Private writes
may already have happened: invalidation and reset are not rollback. Error
responses from ordinary preflight rejection leave all persistent state unchanged.

The real example holds `limit32*quantity32` before admitting a buy limit IOC.
Normal matcher completion follows retirement of every fill; only then is the
stored ticket released. The wrapper publishes final done after release succeeds.
The full hold survives a stalled final fill. Matcher reason4 conservatively
invalidates the ledger and retains its hold. The already consumed book quantity
is not restored. CLEAR can start another credit epoch without clearing the book.
This is an in-flight notional budget, not a cash/position/settlement risk system.

Qualitative architecture risk: LOW storage volume, MEDIUM RAM packing, sequential
service latency and example multiplier mapping. Actual LUT/FF/BRAM/DSP use, timing,
power, PnR and board behavior are unknown and have not been measured.

The approved finite scope is three syntax children and four compile/sim pairs:
A/K/T 1/1/1, 5/7/8, 16/64/32, plus the actual fixed-default IOC composition.
All executable sources/dependencies and the reviewed plan are archived before
the independent oracle's three vector-generation calls. Vectors and their hashes
are durable before the first HDL child. Each child has 20 seconds plus at most
seven seconds of tree termination/drain; first failure stops without retry.

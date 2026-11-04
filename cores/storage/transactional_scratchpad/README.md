# Optimistic multi-context transactional word memory

`transactional_scratchpad` keeps a committed word image and several independent
speculative contexts. Each context caches external reads, forwards its private
writes, then atomically commits its staged words or rejects a changed read
dependency. This adds multiword optimistic transactions beyond the existing
single-word atomic scratchpad and shadow configuration bank. Actual pre-RTL
source/license inspection and the 60-package comparison are in SOURCES.md.

## Commands, validation and lifetimes

One rising-edge `clk`, synchronous high `rst`, no CE, CDC, external memory or
runtime configuration. Public ready/valid are suppressed while reset is high;
hold reset through a rising edge. A command transfers on `c_valid && c_ready`
and its one response on `r_valid && r_ready`. Hold every command field stable
while blocked. One command owns computation and the held response; context
state persists between commands, allowing different contexts to interleave.
No command can intervene in a multiword commit. A new command transfers only
after the prior response retires. All response fields remain stable through
arbitrary backpressure.

| c_op | Action | Context/address/data use |
| --- | --- | --- |
| 0 BEGIN | Open an inactive context with empty read/write logs | Context only |
| 1 READ | Return own staged value, otherwise first-read cached value, otherwise record/read current committed word | Context/address |
| 2 STAGE | Replace the private value at one word; repeated staging consumes one unique write entry | Context/address/data |
| 3 COMMIT | Atomically publish every staged word, or reject conflict; close the context in either case | Context only |
| 4 ABORT | Discard all private state and close an active context | Context only |
| 5 PEEK | Read current committed memory without a transaction or dependency | Address only |
| 6 CLEAR | Zero committed memory and discard every context | All other fields ignored |
| 7 reserved | BAD_OP without mutation | All other fields ignored |

`c_context` is a fixed unsigned 8-bit ID; `c_address` is an unsigned 32-bit
**word index**. Both are checked at full width before narrowing. PEEK ignores
even an invalid context; BEGIN/COMMIT/ABORT ignore even an invalid address.
STAGE data is raw DATA_W-bit unsigned content; other operations ignore data.
No byte masking, endian conversion, sign, scaling, rounding or reserved data
pattern exists. Tags are opaque correlation fields.

BEGIN does not snapshot the whole memory. An external READ records the current
committed value and dependency at that moment. Repeated reads use that cached
value. Reading a staged word returns the newest private value and creates no
new external dependency. Staging after an external read preserves the original
dependency. No staged write is visible through another context or PEEK.

Every successful commit writing an address invalidates every other active
context that has externally read that address. Even identical-value writes and
ABA changes conflict. The conflict is sticky until ABORT or COMMIT closes the
context; BEGIN on it is still ALREADY_ACTIVE. READ/STAGE on a conflicted context
return CONFLICT without changing its private logs. A conflicted COMMIT closes
and discards that context, returning CONFLICT and applying no word.
ABORT succeeds even for a conflicted active context. There is no autonomous
retry, wait queue, nesting, merge, eviction or conflict timeout.

Blind writes create no read dependencies and may commit over another writer;
successful commits serialize in command order. For each successful transaction,
all external values it read still match the committed image immediately before
its commit, so its writes can appear as one atomic event there. This provides
serializable successful transactions, not a whole-memory snapshot at BEGIN or
nonvolatile durability. Context IDs have no generations: callers must serialize
ownership and prevent stale commands from acting on a reused context ID.
All memory access must pass through this service; no side port/coherence exists.

## Responses, errors and reset

Every response echoes `r_op`, `r_context`, `r_address` and `r_tag`, including
ignored fields and errors. `r_data` is the successful READ/PEEK value and zero
otherwise. `r_written` is the number of distinct words published by a successful
COMMIT, zero on every other result including failures. Empty/read-only commits
succeed with written=0. There is one response and no packet/KEEP/LAST interface.

`r_active` and `r_conflict` describe the selected valid context after the command.
They are zero on PEEK/CLEAR/BAD_OP/bad-context. Successful BEGIN returns 1/0;
COMMIT/ABORT return 0/0 even on rejected conflicted COMMIT. Invalid-address
errors report the unchanged valid context's flags. A held ACK describes already
completed mutations; it cannot admit another command or change memory.

| r_status | Meaning |
| --- | --- |
| 0 OK | Operation completed |
| 1 BAD_OP | Reserved opcode 7 |
| 2 BAD_CONTEXT | Relevant context >= CONTEXTS |
| 3 BAD_ADDRESS | Relevant full32-bit address >= DEPTH |
| 4 NOT_ACTIVE | READ/STAGE/COMMIT/ABORT on an inactive valid context |
| 5 ALREADY_ACTIVE | BEGIN on an active context, even if conflicted |
| 6 CONFLICT | READ/STAGE rejected, or COMMIT rejected and closed |

Validation precedence is bad opcode, bad relevant context, bad relevant address,
then lifecycle/conflict. Other errors preserve committed and private state.
No memory-error input or arithmetic-overflow status is needed.

Reset cancels the current command, partially applied commit and held ACK without
a response, and discards **all** prior committed contents/contexts. After
deassertion, CONTEXTS*DEPTH edges sweep read/write masks and zero the committed
bank (during the first DEPTH of those edges). Commands remain blocked. A new
reset restarts the sweep. CLEAR performs the same operation with a tagged ACK.
The cached read/write payload arrays and synchronous read registers are not
reset. Inactive contexts hide old metadata until BEGIN clears their whole row;
valid masks protect all cached payload reads. Reset after partial commit does
not restore the previous image: it restores an all-zero image. Callers must
replay canceled operations and discard old context ownership. No secure erasure
of speculative payload arrays is promised.

## Parameters, RAM organization and bound

| Parameter | Default | Legal range |
| --- | ---: | --- |
| CONTEXTS | 4 | 1..8, including nonpowers of two |
| DEPTH | 16 | 1..64, including nonpowers of two |
| DATA_W | 32 | 1..32 |
| TAG_W | 8 | 1..32 |

Widths TW=max(1,clog2(CONTEXTS)), AW=max(1,clog2(DEPTH)),
CW=max(1,clog2(DEPTH+1)), FW=max(1,clog2(CONTEXTS*DEPTH)) are local.
Illegal static values fail elaboration through the named unresolved
`transactional_scratchpad_invalid_parameters__see_README` instance.

Committed data, read-cache data, staged data, read masks and write masks are
separate banks with selected synchronous reads. Lookup, first-read caching,
staging and publication use separate phases. A commit scans every address;
for each staged word it writes committed memory, then reads each context's
dependency bit and sets a small sticky conflict flag. The single-command owner
hides partial publication. No read-during-write collision value is relied on.
There is no parallel full-bank reset, all-context data comparison, variable
multiplier, divider, vendor primitive or external storage. Small context flags
and write counts are bounded indexed registers; memory mapping is unmeasured.

Logical banks occupy `DEPTH*DATA_W*(1+2*CONTEXTS)+2*CONTEXTS*DEPTH` bits:
**4,736 default / 35,840 maximum**. Context flags/counts add
`CONTEXTS*(CW+2)` = **28 / 72 bits**. All other declared stored scalar/read/output
registers total `56+2*TW+2*AW+FW+5*DATA_W+TAG_W+CW` = **247 / 282 bits**.
Combinational control/address logic is additional. Qualitative resource risk
LOW default/MEDIUM maximum concerns RAM inference and port/address muxing.
No measured LUT/FF/BRAM/DSP count, frequency, power or device fit is claimed.

BEGIN takes DEPTH periods after acceptance to first valid; first external READ
and STAGE take three, cached/own-write READ and PEEK two. Initial errors, ABORT
and conflicted COMMIT respond immediately after acceptance. If K unique words
are staged, successful COMMIT takes `2*DEPTH+K*(1+2*CONTEXTS)+1` periods.
CLEAR takes CONTEXTS*DEPTH. The finite pre-edge monitor allows the conservative
bound `max(CONTEXTS*DEPTH+1,DEPTH*(3+2*CONTEXTS)+3)`, 179 default/1219 maximum.
Earliest transfer is one rising edge after valid. Source gaps and held responses
can delay retirement indefinitely; these are schedules rather than clock-rate
or unconditional wall-clock guarantees.

## Offline files and frozen checks

The complete local production and example closures are `files.f` and
`example/files.f`. `example/transaction_bank4.sv` forwards every default port;
it is an instantiation, not a multi-master arbiter or system integration test.
Package-local attributes preserve UTF-8/LF source bytes under Git checkouts.
From the package root:

```text
iverilog -g2012 -Wall -tnull -s transactional_scratchpad -f files.f
iverilog -g2012 -Wall -tnull -s transaction_bank4 -f example/files.f
```

From repository root, `python -B cores/storage/transactional_scratchpad/run_tests.py`
executes only TEST_PLAN.json. Every compiler/simulator child has a 20-second
limit. A timeout is terminal; there is no retry, fixture shrink or larger limit.
Ordinary failures retain their original report/source hashes before the
unchanged complete matrix reruns. Task temporary vectors/images are removed.

Five C/N/W/T profiles are 1/1/1/1,2/3/5/3,3/8/8/8,4/16/32/8 and8/64/32/32.
The oracle uses unbounded Python committed-write epochs plus per-context
read-value/epoch and private-write dictionaries. It validates commit-time
external values and applies writes as one serial event; it does not model RTL
conflict latches or the invalidation scan. Every main response checks every
committed word, active/conflict/write count and every masked read/write-log
word. Cases cover full-depth writes, disjoint/same-value/ABA conflicts, write
skew, blind-write ordering, forwarding, repeated stage/read, all errors,
abort/reuse, persistent seeded traffic and exhaustive length-three small traces.

Actual next-command stalls and four-clock held results check full field
stability. Immediate observed-boundary reset probes cover every controller
state plus selected middle/partial/held success/conflict/read phases. Every
probe follows with full zero/metadata checks, private visibility, successful
commit/readback, conflict rejection when multislot, abort/reuse and clear.
All 20 first-attempt tool records passed, including eight named illegal
parameter rejections, with no failures/timeouts. Qualification is **LINT_PASS /
UNIT_SIM_PASS / HW_UNVERIFIED**; the wrapper is an INTEGRATION_CANDIDATE by
syntax only. Main traffic completed 4,062 commands, 50,640 committed-word
checks, 341,216 transaction-word checks and 136 successful serial commit
certificates. The 107 immediate reset probes completed 2,191 setup/recovery
commands. Across all nonreset probe/setup/recovery/main activity, counters
recorded 117,229 cycles, 42,462 blocked-command cycles, 26,881 held-response
cycles, 424 committed-word applications and 110 context invalidation events.
Observed first-response sampled maxima were 7/23/74/178/1218 cycles against
bounds 8/24/75/179/1219. Main-only snapshots/certificates and broader activity
counters are distinguished in verification.json. Finite checks do not prove
every legal history or parameter tuple. Synthesis, PnR, STA, hardware and
expanded regression remain NOT_RUN.

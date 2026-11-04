# Exact canonical byte interval set in synchronous RAM

`ram_interval_set` retains a set of covered byte addresses across commands.
ADD unions a range, including endpoint-adjacent ranges. REMOVE subtracts any
range and can split one component into two. COVER measures the exact number
of covered bytes in a request. ENUM returns the unique ascending maximal
components. For example, `[10,20),[30,40)` plus `[20,30)` becomes `[10,40)`;
subtracting `[18,32)` leaves `[10,18),[32,40)`. COVER `[15,35)` then reports6.

The service can collect completed DMA/dirty ranges for a later maintenance
planner and remove spans after their consumer acknowledges them. It stores
coverage metadata. The caller owns payload memory, external completion order,
permissions, cache coherence and the decision to remove a processed span.
Repeated ADD is idempotent; the set retains no original range identity.

`verification.json` is authoritative. LINT_PASS / UNIT_SIM_PASS require the
entire original frozen268-child matrix to pass. Hardware remains HW_UNVERIFIED.
Synthesis, PnR, STA, board, expanded regression and inherited matrices are
excluded. The included example has syntax/instantiation scope only. Source
preflight and actual semantic comparison are in [SOURCES.md](SOURCES.md).

## Parameters and exact geometry

| Parameter | Default | Legal |
|---|---:|---|
| MAX_INTERVALS, N |16|every integer1..64|
| ADDR_W, A |32|every integer1..64|
| TAG_W, T |8|every integer1..32|

I=max(1,clog2 N), C=clog2(N+1), R=2A+1 are internal derived widths.
Illegal static parameters fail elaboration through
`ram_interval_set_invalid_parameters__see_README`.

`c_base[63:0]` is a full unsigned byte address. `c_bytes[64:0]` is a full
unsigned positive byte count. ADD/REMOVE/COVER require base<2^A, bytes>0,
and base+bytes<=2^A. The addition/comparison use66 bits before narrowing;
upper host bits never alias a valid range. Half-open `[base,base+bytes)`
includes base and excludes the end. Whole-space `(0,2^A)` and final byte
`(2^A-1,1)` are legal, including A64 and the full65-bit count2^64.

All lengths, totals and covered counts use A+1 bits. Stored exclusive ends
also use A+1 bits, so end2^A is preserved. Canonical components have positive
length, increasing bases and a strictly positive gap between neighbors.
The maximum reachable component count is min(N,2^(A-1)); A1 has only one
reachable component even when N3 provides three physical slots.

## Commands, publication and reset

All ports use one rising-edge clock, synchronous active-high reset and ordinary
ready/valid. There is no CE or CDC. A source holds valid and every associated
field while blocked. Only `c_valid && c_ready` accepts op/base/bytes/tag.
One command owns calculation and every held output. The next actual command
may be preoffered, and transfers on an edge after final response retirement;
there is no same-edge retirement/admission fallthrough.

| c_op | Action | Relevant geometry |
|---:|---|---|
|0 ADD|Replace S with S union request|base,bytes|
|1 REMOVE|Replace S with S minus request|base,bytes|
|2 COVER|Return exact size of S intersect request and whole-coverage flag|base,bytes|
|3 ENUM|Return all maximal components in ascending order|ignored|
|4 CLEAR|Discard all components and total|ignored|
|5 STATUS|Return retained count/total|ignored|
|6,7|BAD_OP|ignored; opcode rejection has priority|

Capacity counts the final canonical components. An ADD that bridges many
components succeeds at full occupancy. A disjoint ADD or a REMOVE split
requiring N+1 components returns FULL and retains the complete prior set.
Removing an absent range succeeds without changing coverage. Contained or
duplicate additions also succeed. Invalid range and illegal opcode preserve
all retained state. Errors return no partial replacement.

ADD/REMOVE read the active logical bank and build a complete candidate in
the other bank. Only finalized canonical components are written. The first
finalized component beyond N rejects the candidate; later processing could
not merge it because earlier emitted boundaries are already final. Successful
publication swaps the bank/count/total together before presenting the response.
Response acceptance retires an already published operation. CLEAR similarly
clears metadata before its response. No other command can observe a private
prefix or intervene while a response is held.

Hold reset across a rising edge. It immediately gates command-ready and
response-valid low; its active edge cancels the owner and discards the whole
set by clearing count/total/bank metadata. RAM payload and read registers are
unreset. No stale row can be read until a later successful build has written
its complete owned prefix. Reset cancels all source obligations and returns
no response. A consumer treating these ranges as outstanding payload work
must coordinate its own cancellation/reconstruction at that boundary.

## Outputs

Every valid token repeats captured `m_op/m_tag` and post-operation `m_count`
and `m_total`. Failed commands repeat the intact prior count and total.
All fields remain stable under arbitrary backpressure. Fields outside valid
have no transaction meaning; data aliases of the held RAM read register avoid
duplicating its wide row in output registers.

| m_status | Meaning |
|---:|---|
|0 OK|Successful command or nonempty ENUM|
|1 EMPTY|ENUM of the empty set|
|2 BAD_RANGE|Relevant geometry has zero length or leaves the address domain|
|3 FULL|Final replacement needs more than N canonical components|
|4 BAD_OP|Reserved command opcode|

Nonempty ENUM emits one `m_keep=1` token per component. `m_index` is its
zero-based ascending ordinal, `m_base` its A-bit start and `m_bytes` its
positive A+1-bit length. FIRST/LAST identify the first/final token. There is
no additional completion token. Every other command, including empty ENUM,
emits exactly one summary with keep0, first=last1 and zero index/base/bytes.
Only an OK COVER returns `m_covered=|S intersect request|` and
`m_whole=(covered==requested bytes)`; both fields are zero on every other
operation and error.

## Scheduled storage and cycle budget

One packed synchronous single-port RAM has2N rows of `{lo[A],end[A+1]}`.
The two logical banks share that scheduled port; reads and writes occupy
different states. No payload reset, asynchronous array read, all-row
combinational comparison, multiplier, divider, vendor primitive or external
memory is used. One read register is shared by build/query/enumeration.
One finalized-fragment register and a flag retain a possible second fragment;
its fields come from the unchanged read row rather than another wide register.
Fragment length is registered in EMIT_CHECK before the total addition in
EMIT_WRITE. Coverage uses one serial overlap subtraction/accumulation path.

Declared RAM is `2*N*(2*A+1)`:2080 default and16512 maximum bits.
Actual declared clocked scalar/read/fragment storage is
`11*A+2*C+I+T+156`:530 default and912 maximum bits, excluding RAM.
The initial proposal's scalar design ceiling was624/1176 bits; aliasing held
read/counter state and retaining a second-fragment flag saves94/264 bits
against that ceiling. These are source declarations and schedules, without
LUT/FF/BRAM/DSP counts, Fmax, power or device-fit measurements. Qualitative
risk is LOW default/MEDIUM maximum, particularly the65-bit coverage arithmetic
and tool-dependent packing of a wide, shallow memory.

For K old components and J final components, a successful build first presents
its summary exactly `3*K+2*J+4` periods after command acceptance. Valid builds
therefore take at most5N+4 clocks (84/324 default/max). A capacity rejection
fits5N+5. COVER takes2K+3; ENUM first valid takes3, subsequent valid appears
two periods after the previous retirement. CLEAR/STATUS/empty ENUM/BAD_RANGE/
BAD_OP take2. The original frozen test bound6N+16 (112/400) is conservative
for every first result. Backpressure extends ownership; there is no
unconditional wall-clock deadline or throughput promise.

## Immutable finite evidence

Before the first RTL file, prepare.py generated TEST_PLAN SHA256
`589322caca57f8e0992bbb38c379669c71e0af50d16d73f2c9e4e1d2547caa10`.
The six N/A/T profiles are1/1/1,3/1/3,3/4/3,7/16/8,16/32/8,64/64/32.
254 complete JSON/TXT pairs fix every command, tag, expected token, before/
attempted/after row certificate, actual next offer, setup and fresh sequence.
Grouping and exact268 children are immutable:2 lints,6 TB compilations,
254 simulation jobs (101 main/153 reset),6 named parameter rejections.
Each compiler/simulator child has a hard20-second terminal timeout.

The plan contains13268 main commands/14274 output records,258 canceled owners,
1128 completed setup commands/records, and5246 complete fresh commands/9202
records. Only12 specified ENUM prefix records retire from canceled owners.
Owner full mathematical expectations are retained for validation and never
counted as completed owners. Expected actual totals are19642 complete commands,
24616 retired records,19025 real internal next-command accepts,19894 command
accepts and19708 first-valid checks. The258 target occurrences cover19 states
and27 semantic targets, with nine explicit exclusions per A1 profile. Every
fresh fills all reachable rows, repeats one ADD to overwrite the other whole
logical bank, retires the complete ENUM, full-domain COVER and STATUS.

Primary gold uses elementary endpoint atoms with Boolean occupancy and exact
arbitrary-integer weighted integration. It does not implement serial interval
merge or RAM phases. A separate per-byte integer bitmap checks9691 stored
commands for A<=8; an independent event sweep also checked all19900 stored
mathematical commands, including capacity decisions and complete text parsing.
Stored data is not a claim of HDL execution. The TB checks every scheduled
read's ownership/data, synchronous read timing, each finalized private write,
the whole active prefix at first valid, every actual retired field, bounded
first-valid timing, source/output holds and actual next acceptance. The first
falling-edge target cancels before the next active edge.

From this directory, use local Icarus bin/lib on PATH through the runner:
`python -B run_tests.py --seal`, root source preflight, then exactly once
`python -B run_tests.py --run`. `--audit` only reads evidence. Any ordinary
failure preserves exact tested source/plan/seal/receipt/remaining NOT_RUN and
all produced executables before a separate root repair decision. TIMEOUT is
terminal. The package attributes preserve archive artifacts as raw bytes.
`files.f` and `example/files.f` close production dependencies; offline use
needs no fixtures, Python, network, sibling RTL or upstream library.

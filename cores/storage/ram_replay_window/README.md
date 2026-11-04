# Persistent per-context sequence windows

`ram_replay_window` atomically classifies and optionally marks unsigned64
sequence numbers against a retained exact sliding window. Independent contexts
hold their own highest marked number and received set. A packet dispatcher can
use it after validating/authenticating a packet, or a transaction consumer can
detect duplicate delivery within a bounded numeric history. It neither moves
payload nor authenticates traffic. Epoch changes require an explicit clear.

The authoritative states and finite evidence are in `verification.json`:
`LINT_PASS` / `UNIT_SIM_PASS` require its complete frozen matrix to pass;
hardware remains `HW_UNVERIFIED`. No synthesis, PnR, STA, board test or expanded
regression is run. [SOURCES.md](SOURCES.md) records actual semantic dedup and
the complete fixed upstream source/license reads before RTL.

## Exact numeric domain

All sequence values from0 through `2^64-1` are legal. Ordering is ordinary
unsigned numeric order; it is not modular, signed or half-range ordering.
After the head reaches `2^64-1`, a wrapped zero is old rather than a new epoch.
There is no reserved sequence, protocol counter limit, timeout or implicit
epoch rollover. A clear discards history and starts a new empty context.

For an active context with head H, bitmap bit i means `H-i` was marked, for
`0<=i<WINDOW_BITS`. Only nonnegative actual sequence numbers can be marked.
Bit0 is always1. The numeric accepted window is `H-W+1 <= sequence <= H`,
where W=WINDOW_BITS; at exactly age W a number is too old. Unmarked numbers
above H are new. Accepted late numbers leave H unchanged. On a forward gap
d<W the bitmap shifts left by d and bit0 is set; when d>=W all old bits are
discarded and only bit0 is set. W=1 consequently retains only the head and
has no LATE classification. Non-power-of-two widths use exactly W positions.

## Parameters and storage

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `CONTEXTS` |16|every integer1..64|
| `WINDOW_BITS` |64|every integer1..256|
| `TAG_W` |8|every integer1..32|

`IW=max(1,clog2(CONTEXTS))` is internal. Public context indices are full
unsigned32 values, checked against CONTEXTS before narrowing. Zero and the
largest valid index are ordinary independent contexts. Encoded holes, upper
bits and `0xffffffff` cannot alias valid rows. Unsupported parameters fail
elaboration through a named missing parameter-error module.

One packed synchronous-read RAM stores CONTEXTS rows of `(head64,seenW)`:
`CONTEXTS*(64+W)` logical bits, **2048 default /20480 maximum**. A separate
resettable CONTEXTS-bit ownership map guards all unreset RAM data. A valid
MARK writes one row only; PEEK never writes; clears update ownership only.
Read and write phases are disjoint, without read-during-write assumptions.

Including the RAM read register and public response registers, clocked scalar
storage is exactly `234+CONTEXTS+IW+2*W+TAG_W` bits: **390 default /848
maximum**. Combinational temporaries are excluded. There are two64-bit
subtraction expressions, unsigned ordering, bounded bitmap shift/select and
control logic, without multiplication, division, DSP, external memory or
vendor primitive. The wide shift/read word may affect mapping and timing.
Qualitative risk is LOW default /MEDIUM maximum; RAM inference and physical
fit are UNKNOWN. These are declared source bits, not measured FF/LUT/BRAM
counts, Fmax, power or board throughput.

## Ready/valid command ownership

One rising-edge `clk`, synchronous active-high `rst`, no clock enable or CDC.
Transfers occur on `valid && ready`. The command source holds valid and all
fields until acceptance; a response holds valid and every field through
backpressure. One command owns the core through response retirement. A real
next command may be offered while busy and must remain stable until accepted
or reset. There is no simultaneous command acceptance/result retirement;
the next command can transfer on the following rising edge.

Reset immediately gates `c_ready` and `m_valid` low. Its active edge cancels
the pending command/result and clears all ownership metadata. RAM and its
read register are not reset or swept; invalid contexts hide stale contents.
No command from the old epoch survives reset. A canceled source obligation
ends at reset; the caller may replay work after release. Public fields and
decision flags are meaningful only with `m_valid`; they are not event pulses.
There are no FIRST/LAST markers because every command has exactly one result.

Inputs are `c_op[2:0]`, `c_context[31:0]`, `c_sequence[63:0]` and opaque
`c_tag[TAG_W-1:0]`. Configuration is elaboration-only. All fields are unsigned
integers/bit vectors, without byte addresses, fixed-point scale or saturation.
CE-qualified ANSCORE neighbors need an explicit adapter.

| Opcode | Operation | State effect |
| ---: | --- | --- |
|0|MARK|Classify and mark only an unseen admissible sequence|
|1|PEEK|Same classification without any state update|
|2|CLEAR_CTX|Invalidate one context; sequence ignored|
|3|CLEAR_ALL|Invalidate every context; context and sequence ignored|
|4..7|Reserved|BAD_OP; no state update|

Undefined opcode takes priority over context validation. CLEAR_ALL ignores
even out-of-range context values. Other operations reject any invalid context
without a RAM access or state update. Clearing an already empty context is
successful. No implicit eviction of another context occurs.

## Results and atomicity

Every response echoes `m_op`, full32-bit `m_context`, full64-bit `m_sequence`
and `m_tag`. Status values are:

| `m_status` | Meaning for MARK/PEEK |
| ---: | --- |
|0 FIRST|Context is empty before the command|
|1 NEW|Sequence is numerically above the current head|
|2 LATE|Sequence is unseen but inside the retained window|
|3 DUPLICATE|Sequence is already marked inside the window|
|4 TOO_OLD|Head minus sequence is at least W|
|5 CLEARED|CLEAR_CTX or CLEAR_ALL completed|
|6 BAD_CONTEXT|Full context index is out of range|
|7 BAD_OP|Undefined opcode|

`m_accepted` is1 exactly for a MARK/PEEK decision FIRST/NEW/LATE; it describes
admissibility, so PEEK may return1 without writing anything. `m_marked` is1
exactly for those successful MARKs. Duplicate and old MARKs cannot refresh or
otherwise change history. A repeated PEEK of an empty context stays FIRST.

For valid MARK/PEEK, `m_active`, `m_head[63:0]` and `m_seen[W-1:0]` describe
that context after the operation. PEEK returns the unchanged history, even
when it classifies the input NEW or FIRST. An empty selected context has
active=0/head=0/seen=0. Clears and rejected commands return these same zero
snapshot fields and decision flags0; other contexts are retained unless an
actual CLEAR_ALL occurred. All response fields remain stable because later
commands cannot intervene while the output is held.

The successful MARK's RAM and ownership update commit on the edge presenting
its result. Every earlier read/compute phase remains exclusively owned. A
reset during a held result cancels that response and clears all contexts,
including any already committed MARK. There is no external memory error or
completion timeout, and a stalled consumer can block indefinitely.

## Exact clock schedule

Latency is complete periods from the accepting edge to the edge after which
`m_valid` is high, independent of output ready:

| Command | Latency | RAM reads/writes |
| --- | ---: | --- |
|Accepted MARK (FIRST/NEW/LATE)|3|1/1|
|Duplicate/old MARK or any valid PEEK|2|1/0|
|Clear, BAD_CONTEXT, BAD_OP|0|0/0|

The synchronous row read is E+1, classification E+2 and accepted MARK write
E+3. The earliest response transfer is one further edge. Always-ready command
acceptance gaps are therefore5/4/2 clocks respectively. Each held output
period adds directly to service time; caller gaps/stalls have no finite bound.

## Offline closure and frozen evidence

`files.f` contains the sole production source. `example/files.f` also contains
the complete default direct wrapper `sequence_contexts16`. No include,
coefficient generator, initialized image, Go package, external peer, sibling
RTL or network access is required. From this package directory:

```text
iverilog -g2012 -Wall -tnull -s sequence_contexts16 -f example/files.f
python -B run_tests.py --freeze
python -B run_tests.py
```

The delivered plan is already frozen; freeze refuses overwrite. The normal
runner refuses terminal-timeout and successful-matrix retries. It prefers
the repository-local `tools/oss-cad-suite/oss-cad-suite` Icarus/vvp tools.
Every compiler/simulator child has a fixed20-second timeout. A timeout is
terminal; no reduced fixtures, raised limit or retry is allowed. Ordinary
failures preserve exact original source, plan, receipt and temporary artifacts
under history before same-matrix corrections. New temporary outputs use a
task-specific TemporaryDirectory and are removed after capture.

Before the first HDL tool, TEST_PLAN.json fixes18 children: version, combined
core/default-wrapper syntax, five compile/simulate pairs and six named invalid
parameter rejections. Numeric profiles N/W/T are1/1/1,3/3/3,7/17/8,16/64/8,
64/256/32. Maximum RAM/bitmap/context widths are actually simulated. Input and
oracle hashes are frozen; no inherited B20 checker or tool matrix is run.

The primary oracle retains sets of actual unsigned64 numbers per context. It
uses maximum, interval membership and set deletion, without RAM indices,
bitmap shifts or a hardware state machine; only the final expected RAM images
are reconstructed from those integers. Every public output bit, every owned
RAM word, exact first-valid edge and exact RAM read/write schedule is compared.
Fixtures cover all opcodes/statuses, every context, full-width invalid indices,
PEEK preservation, head/age boundaries, every shift distance through W+1, all64
sequence bits including0/top, empty/clear/reuse, complete small three-command
streams and deterministic mixed traffic. The source preoffers the actual next
frozen command, verifies hold through its real transfer, and stalls every
result. Sixteen observed-boundary reset probes per profile cover all five FSM
states, empty/active reads and evaluation, pending first/new/late writes and
held classification/error/clear responses. W1 aliases the unreachable late
write to a new write. Each reset is followed by a full six-command fresh
MARK/MARK/MARK/PEEK/CLEAR_CTX/PEEK transaction sequence, checking fields, RAM
ownership/content, held output and real retirement. Actual counts and hashes
are retained in the receipt; finite examples do not prove every schedule.

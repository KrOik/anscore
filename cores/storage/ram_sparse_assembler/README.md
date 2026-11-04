# Sparse immutable-word object assembler

`ram_sparse_assembler` collects one positive-length object through arbitrary
indexed word PUTs. The first value at an index is retained. Equal duplicates
are acknowledged without rewriting; conflicting duplicates report an error
without replacing that first value. COMMIT publishes data only after every
index is present, in increasing index order. This suits bounded reassembly or
out-of-order result collection where partial objects must remain private.

`verification.json` is authoritative for `LINT_PASS` and `UNIT_SIM_PASS`:
both require the entire frozen matrix. Physical behavior remains
`HW_UNVERIFIED`. No synthesis, PnR, STA, board test or expanded regression is
run. [SOURCES.md](SOURCES.md) records semantic dedup and complete fixed-source
preflight. No network protocol compatibility is claimed.

## Parameters and numeric domain

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DEPTH` (N) | 64 | every integer 1..256 |
| `DATA_W` (D) | 8 | every integer 1..64 |
| `TAG_W` (T) | 8 | every integer 1..32 |

`AW=max(1,clog2(N))`, `CW=clog2(N+1)`. Unsupported parameters fail elaboration
through the named missing module
`ram_sparse_assembler_invalid_parameters__see_README`.

Inputs are `c_op[2:0]`, `c_length[63:0]`, `c_offset[63:0]`, opaque
`c_data[D-1:0]` and opaque `c_tag[T-1:0]`. Lengths and offsets are unsigned
64-bit **word** counts and indices, checked before narrowing. They are neither
byte addresses nor modular values. A legal object has length 1..N and offsets
0..length-1. All data bit patterns and tags are legal. There is no empty
object, truncation, padding, arithmetic interpretation or implicit extension.

## Command ownership and operations

One rising-edge clock, synchronous active-high reset, no CE or CDC. Transfers
occur on `valid && ready`. A source holds valid and every command field until
acceptance. One accepted command owns the core until its entire response
retires. A real next command may be offered during that interval and must
stay stable through its eventual acceptance or reset. Command acceptance and
response retirement never share an edge; acceptance can occur on the next
rising edge. A stalled consumer can block indefinitely.

An object is open exactly when the internal length is nonzero. BEGIN cannot
replace an open object. Every operation except a complete COMMIT returns one
ACK. Complete COMMIT returns exactly length data tokens, with no extra ACK.

| Opcode | Operation | Effect |
| ---: | --- | --- |
| 0 | BEGIN | If closed and length 1..N, open an empty object and clear ownership metadata |
| 1 | PUT | Require an open object and in-range offset; retain first value, classify duplicates |
| 2 | COMMIT | Require an open, fully covered object; replay every word in index order |
| 3 | ABORT | Clear metadata and close, including when already closed |
| 4 | STATUS | Return current metadata without any mutation |
| 5..7 | Reserved | BAD_OP, with no mutation |

Reserved opcode checking has highest priority. BEGIN checks ALREADY_OPEN
before checking length. PUT checks NOT_OPEN before its full-width offset.
COMMIT checks NOT_OPEN before INCOMPLETE. Other fields are ignored by each
operation: PUT ignores length; COMMIT, ABORT and STATUS ignore length, offset
and data. Ignored fields may contain all ones without changing behavior.

| Status | Name | Meaning |
| ---: | --- | --- |
| 0 | OK | Successful BEGIN, new PUT, complete COMMIT, ABORT or STATUS |
| 1 | DUPLICATE | PUT equals the retained value at an already owned index |
| 2 | CONFLICT | PUT differs from the retained value; first value stays intact |
| 3 | INCOMPLETE | COMMIT finds missing positions; partial object is retained |
| 4 | NOT_OPEN | PUT or COMMIT has no active object |
| 5 | ALREADY_OPEN | BEGIN cannot replace the active object |
| 6 | RANGE | Closed BEGIN length is zero or greater than N, or active PUT offset is outside length |
| 7 | BAD_OP | Reserved opcode |

Errors and STATUS never modify payload or metadata. A new PUT writes one RAM
word and sets one ownership bit. Both kinds of duplicate read one word and
write nothing. There is no provisional data output, completion timeout,
automatic eviction, implicit abort or external memory error mechanism.

## Response and reset contract

Every valid response echoes `m_op[2:0]` and `m_tag[T-1:0]` and supplies
`m_status[2:0]`. `m_total[CW-1:0]` and `m_filled[CW-1:0]` are the object's
length and unique-word count. All fields remain stable while blocked.

An ACK has `m_keep=0`, `m_first=m_last=1`, `m_index=0`, `m_data=0`; its total
and filled fields describe the active object after the operation. Thus ABORT
returns zero/zero, an error preserves the prior snapshot, and a new PUT
includes the newly owned word. An inactive STATUS returns zero/zero.

A complete COMMIT has `m_keep=1`, OK status, increasing
`m_index[AW-1:0]` from zero through length-1, the retained `m_data[D-1:0]`,
FIRST only at index zero and LAST only at length-1. Every data token repeats
total=filled=length. The complete object stays internally owned throughout
every held data token, including the last. Only the final data handshake
clears length, filled and ownership and closes the object. A later STATUS
therefore returns zero/zero. A singleton token has FIRST and LAST together.

Reset immediately gates `c_ready`, `m_valid`, KEEP, FIRST and LAST low. Its
active edge cancels pending work/output and clears all ownership, counts and
output registers. Payload RAM and its read register are not reset or swept;
the cleared metadata hides stale words. Nothing from the prior epoch can be
published after release. Reset ends any outstanding source hold obligation.
Except for the gated markers, fields are meaningful only with `m_valid`.

## Source storage and exact clocks

One synchronous-read payload RAM contains `N*D` logical bits: **512 default /
16384 maximum**. An N-bit resettable ownership bitmap guards the payload.
The read and write phases are disjoint; no read-during-write mode is assumed.
BEGIN and ABORT clear metadata without a payload sweep. The output data
register also holds a pending PUT operand while output is invalid, avoiding a
second input-word register. A separate unreset D-bit register holds RAM reads.

Including the read register and public response registers, declared clocked
scalar storage is exactly `9+N+AW+4*CW+2*D+T` bits: **131 default / 469
maximum**. The remaining logic consists of unsigned range comparisons,
duplicate equality, bounded selection, counters and control, without DSP,
division, external memory or vendor primitives. Qualitative implementation
risk is LOW default / MEDIUM maximum; RAM inference and physical fit are
UNKNOWN. Source bits are not measured LUT/FF/BRAM, Fmax, power or throughput.

Latency counts complete periods from command acceptance edge E to the edge
after which the first response is valid, independent of ready:

| Operation | First-valid latency | RAM reads / writes before first response |
| --- | ---: | ---: |
| New in-range PUT | 1 | 0 / 1 |
| Equal or conflicting duplicate PUT | 2 | 1 / 0 |
| Complete COMMIT | 2 | 1 / 0 |
| Every other ACK | 0 | 0 / 0 |

STORE writes at E+1. Duplicate PUT reads at E+1 and compares at E+2.
Complete COMMIT reads at E+1 and presents its first word at E+2. After each
nonfinal data handshake H, the next read is H+1 and next word is valid at
H+2, so always-ready data transfers are three clocks apart. No extra reads
occur while an output is held. The earliest transfer is one edge after
first-valid. Always-ready command acceptance gaps for ACKs are latency+2;
for a complete length-L COMMIT the gap is exactly `3*L+1` clocks. Each
additional blocked output period adds directly to service time.

## Offline closure and frozen finite evidence

`files.f` contains the sole production RTL. `example/files.f` adds the complete
default direct wrapper `sparse_object64`. No generated memory image, include,
sibling core, third-party source, network, external peer or external RAM is
required. From this package directory, qualification uses:

```text
python -B run_tests.py --seal-source
python -B run_tests.py
```

The delivered `TEST_PLAN.json` was frozen before any RTL implementation and
must not be regenerated. Its input vectors, dictionary oracle hashes,
profiles, checks and reset targets are fixed. `SOURCE_FREEZE.json` separately
binds the complete source set before the first HDL tool. The delivered source
seal is already present. A successful frozen matrix cannot be rerun or
resealed. An ordinary failure archives the exact original source, plan,
seal, receipt, input and partial output before a correction using the same
matrix; a timeout is terminal, with no retry, fixture reduction or larger
limit. Every compiler/simulator child has a fixed 20-second limit.

The runner uses repository-local OSS CAD Suite Icarus/vvp when available.
Exactly 18 children are planned: version, combined core/default-wrapper
syntax, five compile/simulation pairs, and six named invalid-static parameter
rejections. Profiles N/D/T are 1/1/1, 3/5/3, 17/8/8, 64/8/8 and 256/64/32.
The plan fixes 9610 main commands and 10282 output tokens in total. Six
rejections cover N=0/257, D=0/65 and T=0/33. No inherited matrix is run.

The independent functional oracle is a plain sparse dictionary that retains
the first value at each numeric offset. A complete publication sorts its
keys. It has no RAM pipeline, controller or ownership-bitmap mutation model.
Every public field and the complete owned RAM image/metadata are compared
after every main output. Every command's exact first-valid edge and RAM
read/write schedule, and all subsequent COMMIT availability/read gaps are
compared. The testbench also checks every nonreset edge for ownership/count
bounds and reads or writes outside the permitted ownership state.

Fixtures exercise all operations/statuses, every length/offset input bit,
full-width invalid values, every data bit, full-depth reverse filling,
same/different duplicates at each position, incomplete-then-complete objects,
error preservation, all 729 singleton length-three command streams and 600
deterministic mixed commands per profile. The actual next frozen command is
offered while busy and held through real acceptance. Every main output is
stalled for at least three edges and checked for stability.

There are 22 immediate observed-boundary reset targets per profile: idle;
pending store; equal/conflicting duplicate read and compare; held BEGIN,
new-PUT, duplicate, conflict, incomplete, not-open, already-open, range and
bad-op ACKs; first replay read/load/data; later replay read/load; middle and
final held data. Singleton later/middle/final cases alias the first word.
Held ACK/data targets also offer a real future ABORT before reset. Each reset
is followed by a full two-object recovery: partial/incomplete, new PUT,
duplicate/conflict, reverse completion and complete replay, closed STATUS,
then a distinct singleton and complete replay. Each recovery has
`min(N,3)+9` commands, checks all fields/owned RAM and real retirement, and
ends closed. Counts and actual hashes are in the receipt. These finite tests
do not prove every possible interleaving.

# Runtime prefix table in synchronous RAM

`ram_prefix_table` maintains canonical unsigned MSB-prefix bindings in volatile
RAM. LOOKUP chooses the longest containing prefix; PUT inserts or replaces an
exact prefix identity; DELETE removes exactly one identity; CLEAR empties all
bindings. No host-generated image, external memory or auxiliary table is needed.
This is a serialized table service for route/address classification, with no
packet forwarding, actual address translation or bus completion claim.

## Parameters and representation

| Parameter | Default | Legal domain |
|---|---:|---|
| SLOTS | 32 | Every integer 1..128, including non-powers of two |
| KEY_W | 32 | 1..64 |
| VALUE_W | 32 | 1..64 |
| TAG_W | 8 | 1..32 |

PW=max(1,clog2(KEY_W+1)), CW=max(1,clog2(SLOTS+1)) and
IW=max(1,clog2(SLOTS)) are derived, not public overrides. Illegal public
parameters reject elaboration through
`ram_prefix_table_invalid_parameters__see_README`.
Keys, values, lengths and counts are unsigned exact integers/raw bits, without
fixed point, rounding, saturation or reserved key/value patterns.

A prefix identity is `(canonical_key,length)`: canonical_key retains the top
length bits and clears every host bit. Thus all KEY_W-bit input keys describe
the same identity at length0; length KEY_W retains the complete key. Host bits
on PUT/DELETE are ignored. There is at most one live binding per identity.
Different lengths remain different identities, even with the same canonical
key. Canonicalization uses a bit-domain definition with no shift-by-width or
negative-shift dependency. Prefixes have no byte/alignment/IP-version meaning.

## Commands, responses and linearization

Ordinary `c_valid && c_ready` accepts all command fields on a rising edge.
Hold every source field while offered and blocked. Only one command owns the
table; the next command waits until the previous held response retires.
`r_valid && r_ready` retires the response. Every response field, including
r_count, remains stable under arbitrary backpressure. There is no CE or CDC.

| c_op | Command | Inputs used |
|---|---|---|
| 0 | LOOKUP | c_key; length/value ignored |
| 1 | PUT | c_key, full32-bit c_length, c_value |
| 2 | DELETE | c_key, full32-bit c_length; value ignored |
| 3 | CLEAR | key/length/value ignored |

The opaque c_tag is returned unchanged. For PUT/DELETE, every unsigned32
length greater than KEY_W is BAD_LENGTH, checked before the narrowed stored
length can affect any entry. LOOKUP/CLEAR accept every c_length bit pattern.
All operation encodings are defined.

| Response | Meaning |
|---|---|
| r_status0 | OK |
| r_status1 | NOT_FOUND for missing LOOKUP/DELETE |
| r_status2 | FULL for an absent PUT with all slots live |
| r_status3 | BAD_LENGTH for PUT/DELETE; no mutation |
| r_found | Matching binding existed before this command |
| r_inserted | Successful new PUT only |
| r_prefix/r_length/r_value | Canonical identity and **prior** value when found; all zero otherwise |
| r_count | Exact live occupancy after the command, 0..SLOTS |

LOOKUP returns the containing binding with greatest length. Equal-length
matches cannot be distinct identities: two equal-length prefixes containing
one key have identical significant bits. PUT never creates duplicates.
Allocation chooses the lowest free physical slot; physical slot numbers are
not part of the public result. Existing PUT succeeds while full and returns
the replaced value, found1/inserted0. New PUT returns prior fields zero,
found0/inserted1. Missing LOOKUP/DELETE and failed PUT return prior fields zero.
DELETE returns the removed identity/value and decrements occupancy only when
found. Deleting a more specific prefix exposes any surviving shorter fallback.
CLEAR returns OK, found0/inserted0, zero prior fields and count0 after its sweep.

Mutations commit **before response presentation**, rather than response ACK:
PUT/DELETE write in their distinct mutation state; CLEAR sets occupancy0 at
acceptance and clears one complete row per cycle. A held response owns the
already committed table, and no following operation can observe an intermediate
sweep. Reset cancels ownership and discards all entries, including mutations
whose responses had not yet transferred. There is no rollback, transaction
log, eviction, enumeration, multi-command atomicity or nonvolatile persistence.

## Reset and architecture

One rising-edge clock; rst is synchronous active-high and must span a rising
edge. Ready/valid gate low whenever rst is high. The active reset edge cancels
capture, RAM read/scan, pending mutation or held response and clears public
response fields/count. After deassertion, SLOTS clocks clear one packed RAM
row each before c_ready becomes high. All stale payload is overwritten before
any new scan; the synchronous read register is overwritten before consumption.
The caller must replay canceled work. There is no fallthrough into a new
command on response retirement.

Packed rows hold `{live,canonical_prefix,length,value}` in one local array.
READ registers one row, CHECK consumes it on the next edge; every operation
that searches examines all SLOTS rows. A shared scan compares either an exact
identity or a containing prefix and retains the longest result. Free capacity
is remembered independently, so replacement succeeds even after a free slot
or at full occupancy. FINISH observes all registered scan decisions, including
the final slot. WRITE/ERASE and reads use disjoint states; read/write collision
behavior is never assumed. CLEAR is a synchronous row write, not an array reset.
There are no parallel all-entry CAM comparisons, variable multipliers/dividers,
generated ROMs, vendor primitives or dependencies outside files.f.

RAM logical bits: `SLOTS*(1+KEY_W+PW+VALUE_W)` = **2,272** default /
**17,408** maximum. Scalar/read/output declarations total
`13+3*(KEY_W+PW+VALUE_W)+4*IW+CW+TAG_W` = **257 / 486** bits.
Combinational canonicalization and comparisons are excluded from stored bits.
These counts do not establish RAM inference, mapped LUT/FF/BRAM use or fit.
Qualitative resource/timing risk is LOW default / MEDIUM maximum from memory
mapping, mask/select logic and wide key comparison. Frequency, power and
device resource use remain unmeasured.

After acceptance, LOOKUP/missing DELETE/FULL present valid after `2*SLOTS+1`
periods; successful PUT/DELETE take `2*SLOTS+2`, CLEAR takes SLOTS, and a
BAD_LENGTH response is presented by the accepting edge. The TB uses a
conservative sampled first-valid bound `2*SLOTS+4`. Next acceptance additionally
waits for response retirement and one IDLE edge. Source gaps and unbounded
response stalls preclude a whole-workload completion deadline. These are RTL
cycle schedules, not hardware clock-rate measurements.

## Offline packaging and bounded evidence

Run `python -B run_tests.py` from this package directory. The standard-library
runner uses installed Icarus/vvp and the repository OSS CAD Suite location.
Every child is capped at20 seconds. A timeout records TIMEOUT_NOT_RUN and
stops this batch; a subsequent invocation refuses to retry a prior timeout.
No fixture reduction, larger timeout or automatic retry exists. Ordinary
failures retain their source hashes and exact tool records in history.
Before checking, previous overall evidence is overwritten with NOT_RUN;
PASS is published only after the entire frozen TEST_PLAN.json and source
stability/format checks complete. Source/vector/dictionary/actual hashes bind
the finite evidence. No network is needed for offline use.

The fixed profiles are S/K/V/T = 1/1/1/1, 3/5/7/3, 16/16/8/8,
32/32/32/8 and 128/64/64/32. Each includes every legal prefix length,
host-bit aliases, /0/full-width boundaries, default fallback after deletion,
full insertion failure, replacement while full, clear, unsigned32 bad lengths,
reordered equivalent identities and360 seeded mixed commands. The minimum
profile additionally covers all729 three-command sequences drawn from nine
choices, each preceded by CLEAR. This is a fixed finite matrix, not a proof
over all parameter combinations or input sequences.

The Python oracle stores an ordinary dictionary of canonical interval
identities and selects the largest-length containing interval by sorting.
It does not reproduce RAM slots, FSM scan order or RTL bit-mask generation.
Every response and every physical slot after every main command is checked
for exact identity/value, occupancy, canonicality and duplicate/extra entries.
All main responses are held at least four clocks; complete source/response
stability and real source/consumer stalls are checked. Fourteen reset probes
per profile assert reset immediately at the observed phase, covering all eight
states, held success/error, interior scan/clear, replacement write and CLEAR
of a live table. Every cancellation runs a complete checked nontrivial recovery
with missing lookup, /0 insert/query/replace, more-specific override/delete
when capacity allows, fallback, delete/miss and CLEAR. Reset behavior is finite
evidence, not exhaustive cancellation proof. Eight illegal parameters must
fail with the named guard;20 tool children are planned.

The complete frozen run passed on its first attempt: **20 completed child
commands**, including all8 named parameter rejections, with zero positive
stderr and no timeout or ordinary failure. No history failure receipt was
needed. Main response and physical-slot counts below exclude recovery/setup
commands. Trace clocks include **all non-reset probe, setup, recovery and main
activity**, because the TB clock counter is not cleared when main capture opens:

| SLOTS / KEY_W / VALUE_W / TAG_W | Main responses | Trace clocks | Physical slot checks |
|---|---:|---:|---:|
| 1 / 1 / 1 / 1 | 3324 | 30884 | 3324 |
| 3 / 5 / 7 / 3 | 446 | 8266 | 1338 |
| 16 / 16 / 8 / 8 | 605 | 30189 | 9680 |
| 32 / 32 / 32 / 8 | 813 | 69358 | 26016 |
| 128 / 64 / 64 / 32 | 1551 | 449139 | 198528 |
| Total | **6739** | **587836** | **238886** |

There were70 immediate reset cancellations with fresh recoveries and743
fully checked recovery/setup commands. The515471 real source-blocked clocks and
33530 held-response clocks also include all non-reset probe/setup/recovery and
main activity. Main oracle coverage includes1476 inserts,
568 replacements (335 while full),369 deletions,268 overlapping-prefix
queries,1619 host-bit aliases,314 BAD_LENGTH responses,208 FULL responses
and768 deterministic replay comparisons. All planned profiles and negatives
completed; no synthesis or expanded test flow was used.

`examples/address_routes32.sv` exposes fixed default ports with no hidden
dependencies; examples/files.f is its full source closure. Core maturity and
actual totals are recorded in verification.json: LINT_PASS / UNIT_SIM_PASS /
HW_UNVERIFIED only after success. The example is an INTEGRATION_CANDIDATE.
No synthesis, PnR, STA, board test or expanded regression is authorized or run.
All text is strict UTF-8/LF. This original implementation is Apache-2.0;
local LICENSE and repository NOTICE apply. [SOURCES.md](SOURCES.md) records the
actual preimplementation source/license review and semantic reuse decision.

# Indexed arbitrary-care rule table in synchronous RAM

Original Apache-2.0 RTL, initially **RTL_CANDIDATE / HW_UNVERIFIED**. The exact
`SOURCE_SEAL.json` and `verification.json` determine finite qualification.
No synthesis, PnR, STA, power, board or hardware result is claimed.

`ram_ternary_rule_table` stores independently indexed ternary rules. A query
returns every matching slot, their exact count, and the action of the lowest
matching slot. Care bits may be anywhere in the key, including noncontiguous
positions. Duplicates, overlapping rules and a zero-care catch-all retain
their independent slot identities. This supports header/address classification
predicates; it performs no packet forwarding or external memory transaction.

## Parameters and exact representation

| Parameter | Default | Every legal integer |
|---|---:|---|
| SLOTS = S | 16 | 1..64, including non-powers of two |
| KEY_W = K | 32 | 1..128 |
| ACTION_W = D | 16 | 1..64 |
| TAG_W = T | 8 | 1..32 |

Derived `I=max(1,clog2(S))`, `C=clog2(S+1)`, `R=2K+D` are not public overrides.
Illegal parameters reject elaboration through the named missing-module marker
`ram_ternary_rule_table_invalid_parameters__see_README`.
All fields are unsigned exact integer/raw bits, without rounding, saturation,
signed arithmetic or reserved key/action values. Slots use all 32 command bits.

Every live slot contains one packed `(pattern,care,action)` row. SET stores
`pattern=value & care`. Query key x matches exactly when every cared position
has the stored bit, equivalently `((x ^ pattern) & care)==0`. Thus care0
matches all keys and all-one care matches one exact key. Uncared input value
bits are ignored by SET. Query uses raw c_value, regardless of c_care.

The existing RAM prefix table permits only contiguous most-significant care
and returns the longest prefix; the region guard uses contiguous intervals;
the hash table uses exact identity. None stores independent arbitrary-care
slots with all-match output and lowest-slot priority. A single 128-bit rule
caring only about bit0 classifies all even keys; representing that set as
prefixes requires 2^127 exact prefixes.

## Interface, commands and response contract

One rising-edge clock, synchronous active-high rst, ordinary ready/valid,
no CE or CDC. `c_valid && c_ready` captures the entire command. Producers hold
valid and every command field while blocked. One owner includes execution
and the held response. The next command can transfer on the edge after
response retirement, never on the retirement edge. No command pipelining.

Command ports: c_valid/c_ready, c_op[2:0], c_slot[31:0], c_value[K-1:0],
c_care[K-1:0], c_action[D-1:0], c_tag[T-1:0].

| c_op | Operation | Relevant inputs and behavior |
|---:|---|---|
|0|QUERY|c_value key; scans all S slots without changing rules|
|1|SET|slot/value/care/action; inserts or replaces the complete row|
|2|DELETE|slot; removes one live row|
|3|GET|slot; reads one live canonical row|
|4|CLEAR|empties all live metadata; slot/value/care/action ignored|
|5|STATUS|returns live count; all geometry ignored|
|6,7|BAD_OP|all geometry ignored, no mutation|

SET/DELETE/GET validate the complete unsigned32 slot `< S` before narrowing
or using a RAM address. Invalid relevant slots return BAD_SLOT. SET replacement
succeeds when all slots are live. DELETE/GET on an inactive slot return
NOT_LIVE without changing any slot. Opcode error has priority over ignored
slot geometry. The tag is opaque and returned exactly.

Response ports: m_valid/m_ready, m_op[2:0], m_status[2:0], m_tag[T-1:0],
m_live_count[C-1:0], m_found, m_match_mask[S-1:0], m_match_count[C-1:0],
m_slot[31:0], m_pattern[K-1:0], m_care[K-1:0], m_action[D-1:0].
Every command produces exactly one response, with no LAST or extra record.

| m_status | Meaning |
|---:|---|
|0|OK|
|1|MISS for a query without any match|
|2|BAD_SLOT for relevant full32 slot outside [0,S)|
|3|BAD_OP for opcode6 or7|
|4|NOT_LIVE for DELETE/GET on an inactive slot|

Every response includes the post-command live count and echoed opcode/tag.
QUERY returns the complete match mask/count, found, lowest matching slot and
its action. Query pattern/care are zero. A miss has zero descriptor/match
fields. Successful SET/GET return found1, the selected slot and complete
canonical rule; match mask/count are zero. Other operations and every error
have found0 and all descriptor/match fields zero. The operation has committed
before m_valid; retirement acknowledges the already-completed mutation.
Every response field is stable under arbitrary sink backpressure.

Reset immediately gates c_ready/m_valid low at the asserted level. Its active
edge discards the owner and clears the live bitmap/count and control state.
Payload RAM and its read-data register deliberately do not reset. Every
post-reset read requires a live bit established by a new SET. A canceled
command emits no retired response, including a held response canceled by reset.

## Architecture, resource declarations and timing

One bank has S words of R bits. SET writes a whole packed row using the single
port. QUERY alternates synchronous READ and MATCH, skipping a RAM read for
inactive slots; it still visits every slot. GET uses READ then FINISH. One
K-bit XOR/AND/reduction matcher is reused across rows, with a live/result
bitmap and incrementing slot index. There is no whole-array CAM, asynchronous
payload read, resettable payload, multiplier, divider, DSP or vendor primitive.

Logical RAM is `S*(2K+D)`: **1280 default /20480 maximum bits**. The actual
sequential scalar declarations, including the synchronous read-data register,
are counted below; combinational wires are excluded.

| Declaration | Bits |
|---|---:|
|cmd_q, read_q|2R|
|live_q, match_q|2S|
|best_action_q|D|
|scan_q, winner_q|2I|
|live_count_q, match_count_q|2C|
|tag_q|T|
|slot_q|32|
|op_q, status_q|6|
|state_q, valid_q|5|
|Total|2R+2S+D+2I+2C+T+43 = **277 default /933 maximum**|

The original planning ceilings were320/1152 scalar bits. Actual declarations
fit them. Structural risk is LOW at default and MEDIUM at maximum: the
128-bit match reduction, wide shallow RAM and output bitmap can constrain
mapping/timing. Shallow RAM can map to registers or fragmented memory. These
are source counts and qualitative risks, not mapped LUT/FF/BRAM/frequency
measurements. Resettable live metadata costs S bits but avoids clearing RAM.

With command acceptance called edge0, actual states imply:

| Operation | First m_valid edge | Default / maximum |
|---|---:|---:|
|QUERY|2S+2|34 /130|
|SET valid slot|2|2 /2|
|GET live slot|3|3 /3|
|GET inactive, DELETE, CLEAR, STATUS, errors|1|1 /1|

QUERY VALIDATE is edge1, READ edge2 and MATCH edge3. Last MATCH is edge2S+1,
then FINISH publishes at edge2S+2. SET validates at1 and writes/publishes at2.
GET reads at2 and publishes at3. The source may stop presenting commands and
the sink may stall forever; neither wait has a finite bound. With immediate
response acceptance, the minimum next command gap is first-valid latency+2
clocks. No hardware throughput or clock frequency is implied.

## Fixed finite qualification

`prepare.py` generated TEST_PLAN and all fixtures before RTL existed. It
refuses preparation when the plan or RTL already exists. The independent
`audit_fixtures.py` verified every JSON and TXT record, canonical live row,
before/after state and expected response without importing the generator.
The primary gold expands actual accepted key sets at K<=4; larger keys use
ternary-string regular expressions. A separate per-position binary relation
crosschecks each query. No external algorithm or oracle was imported.

| S/K/D/T | Main | Reset setup | Fresh | Completed | Reset |
|---|---:|---:|---:|---:|---:|
|1/1/1/1|328|56|210|594|30|
|3/4/3/3|1970|128|385|2483|35|
|7/9/8/5|404|252|665|1321|35|
|16/32/16/8|596|531|1295|2422|35|
|17/64/32/16|794|562|1365|2721|35|
|64/128/64/32|1460|2019|4655|8134|35|
|Total|5552|3548|8575|17675|205|

Only K1/K4 are exhaustively enumerated: 3 and81 ternary patterns against
2 and16 keys, respectively, totaling6 and1296 pattern/key pairs. Larger K
profiles use fixed finite patterns, one-care-bit sweeps, all-slot overlaps,
noncontiguous masks and four seeded64-command groups. No exponential
large-domain test is implied. Cases cover full-table replacements, every
slot, canonical ignored bits, duplicate catch-alls, lowest priority after
deletion, last-row hit/miss, invalid full32 slots and both bad opcodes.

The frozen reset_targets ledger has35 real Boolean predicates, covering all
seven states, partial query accumulation, first/middle/last rows, inactive
reads, owned GET, before-write new/replacement SET, published SET/DELETE/CLEAR,
full STATUS, every error, held hit/miss and the actual blocked next command.
S1 excludes four multi-slot predicates; K1 excludes noncontiguous care.
Every canceled owner has zero retired records. The actual next command is
the first fresh SET. Reset is asserted immediately after the exact predicate,
before another active edge. Gates, zero live metadata and unchanged payload
RAM/read-data are checked. Fresh recovery executes SET and GET for every
slot, three queries, STATUS and CLEAR: exactly2S+5 complete commands. Every
fresh sequence finishes empty. Reset jobs contain two fixed complete units,
except their predetermined final singleton where needed.

TB checks exact first-valid latency, held response fields and physical live
rows, full pre/post images, real next-command hold/admission, port ownership,
reset and exact command/retirement counts. It emits raw observed response
and packed-row records. The runner independently decodes those records and
compares them against the fixed mathematics. Planned completed snapshots
contain361897 live rows. Inactive payload bits remain unspecified.

TEST_PLAN fixes191 children: two default core/example lints, six profile
builds,175 fixed simulations and eight named invalid-parameter rejections.
SOURCE_SEAL binds every source, fixture, plan, audit and actual executable
hash before the first HDL child. argv substitutes only sealed tool paths and
the absolute own artifacts directory for {TMP}. Tools come from the existing
repository oss-cad-suite bin; bin/lib precede PATH. No PATH shim is launched.
Every child has a hard20-second deadline. First failure/timeout is terminal,
preserving raw stdout/stderr, receipt, source seal, artifacts and later NOT_RUN
records. There is no automatic retry, workload reduction or raised timeout.
Successful exact temporary vvp paths alone are removed; their hashes remain.

From this directory, after authorized preflight:

```text
python -B run_tests.py --freeze
python -B run_tests.py --run
python -B run_tests.py --audit
```

`--run` refuses any existing receipt/output. `--audit` is offline hash/record
decoding only and invokes no HDL or mathematical generator. `files.f` is the
production list; `example/files.f` lists the complete ternary_rules16 wrapper.
Finite simulation does not prove all schedules, formal correctness or hardware
mapping. B25's stopped Git-read checker is neither rerun nor inherited here.
SOURCES.md records the full read-only upstream license/source preflight.

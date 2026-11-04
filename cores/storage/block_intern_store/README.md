# Exact reference-counted block store

`block_intern_store` interns complete immutable fixed-size blocks. Identical
content shares a physical slot and increments its reference count. Releasing
the final reference frees the slot. Exact full-word comparison determines
identity; no hash-only equality, caller-supplied address identity or eviction
is used. Source/license preflight and the 56-package semantic comparison are
in [SOURCES.md](SOURCES.md).

## Commands and ownership

All ports share rising-edge `clk`, synchronous active-high `rst`, and ordinary
ready/valid. There is no CE, CDC, external memory or runtime configuration.
Hold reset across a rising edge. Commands transfer on `c_valid && c_ready`;
data on `d_valid && d_ready`; responses on `r_valid && r_ready`. A source holds
each channel's complete fields until its handshake. Only one command owns the
service, including loading, computation and every held output token. The next
command cannot transfer before the final response retires.

| c_op | Operation | Contract |
| --- | --- | --- |
| 0 | INTERN | Accept exactly WORDS data beats, in increasing word order; command handle ignored |
| 1 | READ | Replay exactly WORDS words of the live handle, without changing references |
| 2 | RELEASE | Remove one reference from the live handle; zero frees its slot |
| 3 | CLEAR | Discard every live block/reference; handle and data ignored |

Command opcode, handle and tag are captured only by the command handshake.
An INTERN's data port becomes ready on the following cycle; data may be
preoffered and held before then. Data offered for other commands cannot
transfer. Each INTERN consumes exactly WORDS beats even if the store is full;
there is no keep, last, cancellation or partial-block command. Missing data
waits indefinitely until reset. The source owns framing/counting and must not
send an extra beat as part of that command. Data-channel fields have no effect
without their own handshake. Raw unsigned DATA_W-bit words have no rounding,
sign, alignment, endian conversion or reserved bit pattern.

INTERN searches all live content before deciding FULL, including slots after
the first free one. A match increments its reference count and returns its
existing handle. A miss copies the candidate to the lowest free handle and
publishes it at reference count one only after every word has been copied.
No two live slots hold identical content. A match at the maximum reference
count is rejected without increment, allocation or eviction, even when free
slots exist. READ does not acquire a reference. RELEASE must correspond to
one outstanding caller-owned reference; multiple references share the handle.

Handles are unsigned 32-bit slot IDs. READ/RELEASE check the full value against
SLOTS before narrowing; out-of-range IDs never alias a slot. There is no
generation: once a freed handle is reused, a stale READ or RELEASE can access
the new block. The caller must prevent stale or excess releases, including
after clear/reset. This is a storage-lifetime service, not an isolation or
authentication mechanism. Tags are correlation only and do not own data.

## Responses, mutation and reset

| r_status | Meaning |
| --- | --- |
| 0 OK | Command succeeded |
| 1 BAD_HANDLE | READ/RELEASE unsigned handle >= SLOTS |
| 2 NOT_LIVE | In-range READ/RELEASE has zero references |
| 3 REFCOUNT_FULL | Exact INTERN match already has 2^REF_W-1 references |
| 4 FULL | INTERN is absent and every slot is live |

Every response echoes captured `r_op` and `r_tag`. Successful INTERN/RELEASE
return the affected handle and its post-command `r_refs`; successful READ
returns its handle and unchanged reference count on every word. `r_count`
is post-command live-slot occupancy, not total references. `r_shared=1` only
for a successful matching INTERN. It is zero on newly allocated INTERN,
READ, RELEASE, CLEAR and all errors. Error/CLEAR target handle and refs are
canonically zero. All operation encodings are defined.

A successful READ has `r_keep=1`, `r_index=0..WORDS-1`, stored `r_data`, and
first/last markers on its first/final words. All other results are one masked
token: keep=0, data/index=0, first=last=1. Successful last-reference RELEASE
still reports the released handle, with refs=0. All fields remain stable
through arbitrary output backpressure. Invalid output fields have no meaning.
Mutations finish before ACK presentation; held ACK and READ cannot admit or
mutate another command. READ never changes ownership, including on handshake.

Reset immediately suppresses public ready/valid. Its active edge cancels the
current command, partial payload copy and held output without a response and
discards all previously committed blocks. After deassertion, SLOTS edges clear
reference metadata before command-ready returns; another reset restarts the
sweep. CLEAR performs the same metadata sweep and returns an ACK. Payload and
scratch RAM are not reset or erased. Zero metadata hides stale payload; a new
slot is fully overwritten before publication, and all scratch words are
loaded before comparison. Reset/clear provide no data-erasure guarantee.
Callers must replay canceled work and quiesce old handle users.

## Parameters and serial architecture

| Parameter | Default | Legal range |
| --- | ---: | --- |
| SLOTS | 16 | 1..32, including nonpowers of two |
| WORDS | 4 | 1..16, including nonpowers of two |
| DATA_W | 32 | 1..32 |
| REF_W | 8 | 1..16 |
| TAG_W | 8 | 1..32 |

Derived widths are local: IW=max(1,clog2(SLOTS)), WW=max(1,clog2(WORDS)),
CW=max(1,clog2(SLOTS+1)). Illegal static settings fail elaboration through
`block_intern_store_invalid_parameters__see_README`.

One candidate scratch bank and one payload bank each provide a synchronous
word read, alongside a synchronous reference bank. The controller reads one
slot's references, compares live words serially, and stops at the first
mismatch. Copy reads and writes use separate phases. Reference updates and
payload writes never depend on a read-during-write collision value. Address
stride WORDS is a constant; no variable multiplier, divider, parallel CAM,
vendor primitive, generated ROM or external dependency is required. Memory
mapping is unmeasured and tiny arrays may map to registers.

Logical arrays occupy `SLOTS*WORDS*DATA_W + WORDS*DATA_W + SLOTS*REF_W` bits:
**2,304 default / 17,408 maximum**. Stored scalar registers are exactly
`44 + TAG_W + 2*REF_W + 2*DATA_W + 3*IW + WW + CW` bits:
**151 default / 197 maximum**. This includes state, reference/data read
registers, indices, occupancy, flags and output registers. Combinational
address/comparison/control logic is additional. No synthesized LUT/FF/BRAM,
Fmax, power or device-fit measurement exists. Qualitative resource risk is
LOW at default and MEDIUM at maximum because of RAM mapping and address muxing.

From the final INTERN data transfer, first-response valid is bounded by
`SLOTS*(2+2*WORDS)+2*WORDS+7` periods; the finite monitor allows one extra
sampled edge. The same conservative bound covers all commands after acceptance
except INTERN loading. CLEAR takes SLOTS periods. Successful READ takes three
periods from command acceptance to first valid; subsequent words become valid
one period after a preceding handshake and always-ready transfers are two
periods apart. Initial bad handles respond immediately after acceptance;
not-live handles take two periods; RELEASE takes three. Source gaps/missing
data and output backpressure add unbounded delay. These are controller bounds,
not measured clock/throughput claims.

## Offline use and finite evidence

`files.f` is the complete production closure; `example/files.f` adds a default
16-block wrapper exposing every port. Run from this package directory:

```text
iverilog -g2012 -Wall -tnull -s block_intern_store -f files.f
iverilog -g2012 -Wall -tnull -s block_store16 -f example/files.f
```

The example is an instantiation, not a DMA integration. From repository root,
`python -B cores/storage/block_intern_store/run_tests.py` runs only the frozen
[TEST_PLAN.json](TEST_PLAN.json), with every compiler/simulator child limited
to 20 seconds. A timeout is terminal for this batch; ordinary failures retain
their original source/report hashes before the unchanged full matrix reruns.
No synthesis, PnR, STA, hardware or expanded regression is authorized here.

Five SLOTS/WORDS/DATA_W/REF_W/TAG_W profiles are 1/1/1/1/1, 3/3/5/2/3,
8/4/8/3/8, 16/4/32/8/8 and 32/16/32/16/32. The content-keyed Python oracle
models complete immutable values and counts, without the RTL's RAM schedule.
Every response field and every physical live slot's references/words are
checked. Cases cover capacity, exact duplicates while full, word mismatches,
release/reuse, invalid full32-bit handles, deterministic persistent traffic,
and exhaustive length-three small command sequences. Refcount saturation is
exercised only for REF_W<=8; the maximum 16-bit profile does not reach 65535.
Real command/data stalls and four-clock holds on every token are monitored.

Immediate observed-boundary resets cover all reachable states (INCREMENT is
unreachable at REF_W=1), mid-clear, held ACK/READ with preoffered command/data,
and partial copy/replay when WORDS>1. Every probe performs fresh allocation,
duplicate/saturation, full readback, release, reuse, clear and missing read;
multislot profiles also preserve a neighbor. Finite evidence and current
source hashes are recorded in `verification.json`. All 22 qualified child invocations passed: **LINT_PASS / UNIT_SIM_PASS /
INTEGRATION_CANDIDATE / HW_UNVERIFIED**; the example is syntax-only. There
were no ordinary failures or timeouts. Main traffic produced 3,594 commands,
4,618 response tokens and 58,274 full physical slot checks. The 97 immediate
reset probes completed 1,166 setup/recovery commands. Across all nonreset
probe/setup/recovery/main activity, counters recorded 110,889 cycles, 62,813
command-blocked cycles, 30,550 data-blocked cycles, 28,860 held-response cycles,
6,597 word comparisons and 4,678 payload writes. Main-only response/coverage
counters are distinguished from those wider activity counters. Finite tests
do not prove arbitrary histories or every legal parameter tuple.

Package-local `.gitattributes` fixes every file to LF even with a CRLF-default
Git checkout. This line-ending policy and this note were added during source
packaging after the qualified matrix, with no RTL, TB, oracle or vector change
and no numerical rerun. Current hashes bind the packaging files as well.

# Shared/exclusive byte-range lock manager

`range_lock_manager` tracks the lifetimes of DMA address hazards. Overlapping
shared readers can hold separate locks; an exclusive writer conflicts with every
overlapping holder. Callers supply the address range. The core issues handles,
validates owner/handle releases and atomically replaces a lock's range or mode.
A failed replacement retains the old lock. It does not allocate payload space,
move data, queue waiters or issue bus transactions.

Maturity: **LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED**. The fixed default
wrapper is **LINT_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. No synthesis,
PnR, STA, board work, PPA measurement or expanded regression was run.

## Offline use and parameters

From the package directory:

```text
iverilog -g2012 -Wall -tnull -s range_lock_manager -f files.f
iverilog -g2012 -Wall -tnull -s dma_hazards8 -f example/files.f
python -B run_tests.py
```

The runner uses standard-library Python, local Icarus/vvp and temporary vectors.
It prefers `IVERILOG` / `VVP`, the workspace OSS CAD Suite, then PATH. Each child
process has its own **20-second timeout**. At entry the report is replaced by
NOT_RUN; only a complete passing run publishes PASS. No prior PASS survives a
failed rerun. No network, include, sibling source, vendor primitive, generated
ROM or external initialization file is required. `files.f` closes the core;
`example/files.f` adds `dma_hazards8`, a fixed default wrapper with every port
exposed. These paths are relative to the package root.

| Parameter | Default | Legal |
| --- | ---: | --- |
| `ADDR_W` | 32 | 8..64 |
| `SLOTS` | 8 | 1..32 |
| `GEN_W` | 8 | 1..32 |
| `OWNER_W` | 8 | 1..32 |
| `TAG_W` | 8 | 1..32 |

Illegal parameters fail elaboration through the named undefined module
`range_lock_manager_invalid_parameter__see_README`. All address, length, owner,
generation, index and count fields are unsigned integers. There is no numeric
scale, saturation or rounding. The public slot input is 32 bits, so malformed
indices are checked before truncation to an internal array index.

## Command and result ports

Every `s_valid && s_ready` rising edge accepts one command. The source holds
valid and **all** fields stable until acceptance or reset. The core owns one
command/result at a time. The source may offer a pending next command while
busy; it cannot change the current owner. The sink can stall arbitrarily, and
valid plus **all** result fields remain stable until handshake or reset.
There is one clock, no CE port and no CDC. A CE-qualified peer needs an adapter.

| Input | Width | Meaning |
| --- | ---: | --- |
| `s_op` | 2 | 0 TRY_ACQUIRE, 1 RELEASE, 2 REPLACE, 3 SNAPSHOT |
| `s_base` | `ADDR_W` | First byte of a proposed range |
| `s_length` | `ADDR_W+1` | Positive number of bytes; can encode the whole address space |
| `s_exclusive` | 1 | 0 shared reader, 1 exclusive holder |
| `s_owner` | `OWNER_W` | Owner identity recorded at acquisition and checked on keyed operations |
| `s_slot` | 32 | Slot component of a handle |
| `s_generation` | `GEN_W` | Nonzero generation component of a handle |
| `s_tag` | `TAG_W` | Request tag copied to the one result |

TRY_ACQUIRE ignores the supplied slot/generation. Its proposed interval is
`[base, base+length)` in unbounded integer arithmetic. Zero length or an end
above `2^ADDR_W` is BAD_RANGE. A full-space interval `(base=0,length=2^ADDR_W)`
and a last-byte interval `(base=2^ADDR_W-1,length=1)` are legal. Shared intervals
may overlap each other. An intersection conflicts if either holder is
exclusive; disjoint or exactly adjacent intervals never conflict. Separate
locks with the same owner still conflict by this rule. No implicit reentrancy
or coalescing occurs. On success the lowest reusable free slot is selected.

RELEASE ignores the proposed geometry and mode. The tuple
`(s_owner,s_slot,s_generation)` must match a live entry. REPLACE first validates
that same tuple, then validates its proposed geometry, then scans all **other**
entries for conflicts. A successful replacement keeps its owner, slot and
generation, replacing the full range and mode in one commit. It needs no free
slot, even when capacity is full. This supports movement, shared-to-exclusive
upgrade and exclusive-to-shared downgrade. There is no split, partial release
or automatic upgrade wait. Any failure leaves the entire original lock intact.

SNAPSHOT ignores every field except op/tag and samples the three ledger counts
at **command acceptance**. It does not enumerate holders or inspect a handle.

| Result | Width | Meaning |
| --- | ---: | --- |
| `m_op / m_tag` | 2 / `TAG_W` | Accepted operation and request tag |
| `m_status` | 3 | Status below; 5..7 never emitted |
| `m_slot / m_generation` | 32 / `GEN_W` | Successful handle |
| `m_owner` | `OWNER_W` | Successful holder identity |
| `m_base / m_length / m_exclusive` | `ADDR_W` / `ADDR_W+1` / 1 | Successful holder geometry/mode |
| `m_conflicts` | `SLOTS` | Complete conflicting live-slot bitmap on CONFLICT only |
| `m_live / m_free / m_retired` | `clog2(SLOTS+1)` each | Post-handshake ledger counts |

| Status | Meaning and priority |
| --- | --- |
| 0 OK | Command succeeds; SNAPSHOT is a successful observation |
| 1 BAD_RANGE | Invalid proposed byte interval |
| 2 CONFLICT | At least one incompatible overlapping live holder |
| 3 FULL | TRY_ACQUIRE found no reusable slot after a conflict-free scan |
| 4 BAD_HANDLE | Zero generation, index outside SLOTS, dead entry, stale generation or owner mismatch |

Acquisition checks range before scanning; conflicts take precedence over FULL.
RELEASE/REPLACE check handle first, so an invalid handle dominates a malformed
replacement range. Every command produces exactly one result; there is no
stream LAST/KEEP or later completion interrupt. For OK acquire/replace, handle
and geometry describe the new holder. For OK release they describe the removed
holder. For SNAPSHOT and **all errors**, handle, owner and geometry fields are
zero. Only CONFLICT has a nonzero conflict bitmap. Counts are always reported,
including errors; their sum is exactly SLOTS.

## Atomic commit, generations and reset boundary

Live-table changes and internal ledger changes happen **only** on
`m_valid && m_ready`. A held successful acquire is a proposed reservation; it
is not live until its result transfers. A held release still owns its original
range. A held replacement still owns the original range/mode. Projected result
counts describe the state **after that handshake**; until then, the table and
internal counts retain their pre-command state. All other commands are blocked
throughout computation and result holding, so no intervening operation can
observe a reservation gap. Errors and snapshots commit nothing. The next
command can transfer at the edge after the prior result retires.

Each slot starts at generation zero. Acquisition increments its retained
generation and returns the new nonzero value. Release retains that generation.
Free slots whose generation is already `2^GEN_W-1` are **retired**, never reused
until reset. The last generation can remain live and be replaced indefinitely;
its release retires the slot. Thus a handle cannot repeat within one reset
epoch. This is deliberate finite-lifetime exhaustion, not wrapping ABA behavior:
there are at most `SLOTS*(2^GEN_W-1)` successful acquisitions in an epoch, and
no individual slot issues more than `2^GEN_W-1`. Lowest-slot selection can retire
frequently reused low slots earlier. `m_free` counts reusable slots; `m_retired`
counts dead slots that cannot be reused. A live last-generation slot is counted
only in `m_live` until released. Replacements consume no generation.

`rst` is synchronous active high and takes priority over all work and commits.
It combinationally suppresses ready/valid while asserted. Hold it across a
rising edge. The reset edge clears control/output ownership, then SLOTS clocks
serially clear table entries before ready is exposed. No table reset fanout or
read of uncleared entries is required. Reset cancels pending commands/results
and **every** live/retired holder. The payload engine and owner bookkeeping must
share that reset epoch or first quiesce their work. Old `(slot,generation)`
tuples can be issued again after reset, so callers must discard all old handles
and pending requests at this boundary. There is no cross-reset stale-handle
guarantee, external epoch field or rollback of already performed DMA accesses.

Owner matching detects accidental release by a different supplied identity;
the owner port is caller-controlled and is **not** an authentication or security
boundary. Locks are cooperative metadata: every participating payload master
must acquire before accessing and retain its handle until its real memory work
has completed. A lost caller can retain a lock forever. There are no waiters,
timeouts, forced revocations, fairness, starvation prevention or deadlock
avoidance claims; a denied caller chooses when to retry. This manager serializes
decisions about concurrent lifetimes, not the payload bus accesses themselves.

## Timing and structural resource budget

From the accepting input edge to first valid after an edge:

| Path | Clock periods |
| --- | ---: |
| SNAPSHOT, bad acquire range, out-of-range slot or zero generation | 0 |
| RELEASE, mismatched indexed handle, bad REPLACE range after a valid handle | 2 |
| Valid-geometry TRY_ACQUIRE, including CONFLICT/FULL | `2*SLOTS+1` |
| Valid-handle/range REPLACE, including CONFLICT | `2*SLOTS+3` |

A scan always visits every slot, with one synchronous read clock and one check
clock per entry, followed by a decision clock. It does not stop at the first
conflict, so the bitmap is complete. TARGET_READ/CHECK similarly separates
handle addressing from use. The first-valid calculation continues while a
pending next command stalls. A result stall holds all core registers and table
contents. With ready high, the result transfers at the next edge after becoming
valid; backpressure extends the command's total ownership duration arbitrarily.

One table entry stores `{live,exclusive,owner,generation,base,inclusive_last}`.
Endpoint validation uses ADDR_W+2 unsigned bits, enough for the largest input
sum before checking it. The stored inclusive endpoint fits ADDR_W bits only
after validation. Release reconstructs length in ADDR_W+1 bits, preserving a
full-space length. There is one shared pair of address comparators, a serial
free-slot selector and a generation incrementer. There is no parallel slot
comparison bank, multiplier, divider, DSP requirement or payload array.

| Declared state | Default bits | Maximum bits |
| --- | ---: | ---: |
| Entry table: `SLOTS*(2*ADDR_W+GEN_W+OWNER_W+2)` | 656 | 6,208 |
| Internal scalar/read/write-stage registers | 326 | 756 |
| Held result fields | 147 | 313 |

The internal count is `3+2*EW+4*IW+3*CW+2+3*ADDR_W+1+4+OWNER_W+2*GEN_W+SLOTS`,
where EW is the entry width and IW is the internal slot-index width. These are
logical declaration counts, not mapped resource measurements. The
table has one synchronous read port and serial writes; initialization, reads
and result-handshake writes occupy disjoint states and never collide. It has
no parallel array reset. The read register is consumed only after a read state.
RAM inference/packing and actual LUT/FF/BRAM mapping remain tool dependent.
Qualitative risk is **LOW** at default and **MEDIUM** at maximum: wide-entry
selection, 64-bit interval compares and result fanout can constrain timing.
No Fmax, power, placement, routing or device-specific memory inference is claimed.

## Independent finite evidence

The report binds the exact local sources and deterministic vector hashes.
Five ADDR_W/SLOTS/GEN_W/OWNER_W/TAG_W profiles are checked:
`8/1/1/1/1`, `12/3/2/3/3`, `24/5/4/5/5`, `32/8/8/8/8`, `64/32/32/32/32`.
All 23 child tool invocations pass their expected outcome, including ten named
negative-parameter elaboration rejections; positive tools have empty stderr.

The independent oracle uses live-holder dictionaries and unbounded half-open
integer ranges. Short ranges use actual byte-set intersections, independently
of the RTL's inclusive pair of comparisons. It checks every result field,
complete conflict bitmaps, lowest reusable slot, generations, owner checks,
ledger counts, rollback and all persistent table bytes after every response.
Every pair of model live entries is also checked for incompatible overlap.
The TB compares **every entry and ledger** against pre/post-command snapshots
at every active checking edge: no change is allowed while computing or holding;
only the expected whole-entry change appears after a result handshake.

The finite run covers **1,595 commands**, 18 successful full-capacity
replacements, 103 failed atomic replacements, 59 multi-holder conflicts,
24 live-generation stale-handle rejections, 38 owner mismatches and 9 retirements.
The three small-generation profiles fully retire all their slots and reject
later acquisitions; wide generations exercise reuse but are not claimed to
exhaust a 32-bit counter. All results are deliberately held for three clocks,
with 4,785 actual held cycles and 25,122 real source-stall cycles. There are
27,213 complete table checks / 528,120 entry comparisons, 7,675 byte-set
intersection checks and 28,651 model pair invariants.

**110 immediate phase resets** cover initialization first/middle/last entries,
idle, indexed read/check, scan read/check at first/middle/last slots, decision,
first held result, and four-clock held acquire/replace/release/error/snapshot
results with a blocked next source. At SLOTS=1 some index boundaries coincide;
the count is probes, not 110 distinct states. Each target invokes `reset_now`
without an intervening active edge. All 110 recoveries then acquire, release and
snapshot a fresh one-byte holder, checking the complete fresh sequence and
subsequent idle cycles for stale results. These deterministic finite tests are
not formal proof, exhaustive legal-space coverage or integration with a real
DMA engine. No hardware evidence is inherited from old packages.

All ten local non-report files are strict UTF-8/LF and SHA256-bound in the
report; dependencies are empty. `SOURCES.md` records semantic deduplication and
the actual fixed-source/full-license preflight. All local RTL, wrapper, tests,
oracle and prose are original Apache-2.0 work. `LICENSE` permits standalone use.

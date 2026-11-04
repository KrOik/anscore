# Persistent command dictionary in synchronous RAM

`ram_hash_table` stores exact key/value bindings between independent GET, PUT,
DELETE and CLEAR commands. Linear probing resolves collisions through every
slot; deletion leaves tombstones so that later keys remain reachable. A PUT
replaces an existing value or uses available capacity without evicting another
key. State persists across commands in **volatile RAM**; clear and reset empty
the dictionary.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Only the bounded checks below have run. No synthesis, PnR, STA, board test or
expanded regression has run. Source/license preflight and the semantic reuse
decision are recorded in [SOURCES.md](SOURCES.md).

## Parameters, storage and hashing

| Parameter | Default | Legal range |
|---|---:|---|
| `SLOTS` | 32 | Power of two, 1 through 256 |
| `KEY_W` | 32 | 1 through 64 bits |
| `VALUE_W` | 32 | 1 through 64 bits |
| `TAG_W` | 8 | 1 through 32 bits |

Derived `COUNT_W=max(1,clog2(SLOTS+1))` represents the exact occupancy from
zero through SLOTS; it is internal, not a public override. Illegal public
parameters deliberately fail elaboration through a named unresolved error
instance.

Keys and values are unsigned raw bit vectors, with no signed/fixed-point
interpretation, reserved key, alignment, byte address, rounding or saturation.
Zero and all-one keys/values are legal. If there are fewer possible key values
than slots, the maximum number of distinct bindings is limited by the key
space. Command tags are opaque and do not participate in lookup.

For more than one slot, `IW=log2(SLOTS)`. The initial slot is the XOR of every
IW-bit chunk of the key, with zero padding at the upper end; equivalently key
bit b contributes to hash bit `b mod IW`. One slot always hashes to zero.
The probe walks `hash, hash+1, ...` modulo SLOTS, visiting at most SLOTS slots.
This is a simple deterministic distribution function, not a cryptographic hash
or an adversarial/constant-time service.

Each slot has EMPTY, LIVE or TOMBSTONE metadata. GET/DELETE terminate at the
first EMPTY slot or after the complete table. PUT remembers the first
tombstone but **continues to search for an existing key**, avoiding duplicate
bindings beyond a deleted slot. At an EMPTY slot or a complete unsuccessful
search, a new PUT uses that first tombstone, otherwise the current EMPTY slot.
A tombstone encountered only on the final probe is also usable. FULL occurs
only for an absent key with all SLOTS live. Replacing an existing key succeeds
even while full.

Tombstones are not automatically compacted, so an empty logical dictionary
can still require full-table misses. CLEAR removes all tombstones. Collisions
and tombstones affect latency rather than usable live capacity.

## Clock, reset, CE and command ownership

All ports use rising-edge `clk`; `rst` is **synchronous active-high** and must
span a rising edge. Public ready/valid are suppressed while reset is high.
There is **no CE**, CDC, external memory or runtime configuration interface.
Legacy CE-qualified streams need an explicit adapter.

Reset cancels the current command and any held response without returning a
completion, sets occupancy to zero, then clears one slot's metadata per active
clock after deassertion. Commands remain blocked for those SLOTS clear edges.
Payload RAM is not reset and can contain stale/uninitialized bits; only LIVE
slots are compared or returned. Caller replay is required after cancellation.
Reset discards all prior bindings; no persistent/nonvolatile recovery is
provided.

Commands transfer on `c_valid && c_ready`; the source holds all fields until
acceptance. Responses transfer on `r_valid && r_ready`, with every response
field stable under arbitrary backpressure. One command is active at a time,
and the next waits for the previous response to retire. Mutations commit
before/with response presentation. The sole command port serializes all table
operations; there is no second master, speculative update or packet boundary.

## Commands and results

| `c_op` | Operation | Key/value use |
|---|---|---|
| 0 | GET | Read key; input value ignored |
| 1 | PUT | Insert or replace key with input value |
| 2 | DELETE | Erase key; input value ignored |
| 3 | CLEAR | Empty table; input key/value ignored |

All operation encodings are defined. `c_tag` is returned unchanged as `r_tag`.

| Response field | Meaning |
|---|---|
| `r_status=0` | Successful GET/PUT/DELETE/CLEAR |
| `r_status=1` | NOT_FOUND on GET/DELETE; no table mutation |
| `r_status=2` | FULL on a new PUT; no table mutation |
| `r_status=3` | Not generated |
| `r_found` | Key existed immediately before GET/PUT/DELETE |
| `r_inserted` | A new binding was successfully inserted by PUT |
| `r_old_value` | Previous value when found, otherwise zero |
| `r_count` | Exact number of live bindings after the command |

A successful existing PUT returns the **old** value, with found=1 and
inserted=0. A new PUT returns found=0, inserted=1 and old_value=0. A successful
DELETE returns the removed value and decrements occupancy. A missing DELETE
does not create a tombstone or decrement occupancy. CLEAR returns status=0,
found=inserted=0, old_value=0 and count=0 after its entire metadata sweep.
There is no bus error, timeout, load-factor cutoff or eviction policy.

The key/value RAM and metadata are not ECC protected. The service does not
provide an enumeration stream, multi-key transaction, concurrent read/write,
nonvolatile persistence or security isolation. Output fields are meaningful
only while r_valid is asserted.

## Architecture, latency and risk

Packed `{key,value}` payload and two-bit metadata use one selected RAM
address. PROBE_READ registers the entry and metadata; PROBE_CHECK compares the
key and decides whether to continue. PUT/DELETE mutate in a separate phase.
CLEAR writes metadata only, one word per cycle. There is no parallel payload
reset, parallel all-key CAM comparison, multiplier, vendor primitive, ROM
generator or external RTL dependency. Physical RAM inference is unmeasured.

Default logical arrays contain **2,048 payload bits + 64 metadata bits**;
maximum parameters contain **32,768 + 512 bits**, excluding scalar control,
read/output registers and XOR/hash/comparator logic. Qualitative resource
risk is **LOW** by default and **MEDIUM** at maximum from memory mapping and
wide key selection/comparison. No area, frequency, power or device-fit result
is claimed.

If k slots are examined, GET and unsuccessful GET/DELETE present a response
`2*k` periods after the command-accepting edge. Successful PUT/DELETE take
`2*k+1`; FULL takes `2*SLOTS`. CLEAR presents its response after SLOTS periods.
Output stalls add occupancy and the next command also waits for response
acceptance/return to idle. These are RTL cycle schedules, not measured clock
rates. A stalled consumer has no unconditional completion-time bound. This
serialized dictionary does not claim one command per cycle.

## Offline use and example

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s ram_hash_table -f files.f
iverilog -g2012 -Wall -tnull -s resource_directory32 -f examples/files.f
```

`files.f` is the complete standalone source closure. The example exposes a
32-binding, 32-bit resource-ID to configuration-word directory with the same
command protocol; `examples/files.f` includes its complete closure. There is
no network, generated table, sibling source or untracked dependency required
after checkout.

## Bounded evidence

From the repository root:

```text
python -B cores/storage/ram_hash_table/check.py
```

The runner prefers local OSS CAD Suite Icarus/vvp, supports IVERILOG/VVP
overrides and caps **every child process at 20 seconds**. Task-specific
temporary vectors/images are removed on exit. `verification.json` records
actual tool commands, outputs, vector/dictionary hashes and current source
hashes. No other verification flow is launched.

| SLOTS / KEY_W / VALUE_W / TAG_W | Records including reset | Responses | Dictionary snapshots |
|---|---:|---:|---:|
| 1 / 1 / 1 / 1 | 3,378 | 3,372 | 3,378 |
| 4 / 4 / 5 / 3 | 485 | 479 | 485 |
| 16 / 16 / 8 / 8 | 557 | 551 | 557 |
| 32 / 32 / 32 / 8 | 652 | 646 | 652 |
| 256 / 64 / 64 / 32 | 1,995 | 1,989 | 1,995 |
| Total | **7,067** | **7,037** | **7,067** |

The functional Python oracle uses a plain dictionary with a capacity limit;
it has no slots, hash buckets, probe state or tombstones. After **every**
record, the TB checks the physical LIVE table against a sorted dictionary
snapshot, independently of slot placement, and detects duplicate/extra keys,
wrong values and occupancy errors. This inspects 545,814 physical slots.
A separate chunk-fold reference checks the initial hash and constructs
wraparound collision fixtures; it does not determine functional results.

Cases include all 729 length-three sequences drawn from nine small command
choices on the one-slot/one-bit configuration (each sequence starts cleared),
full capacity/misses, replacement while full, deletion at a collision-chain
head/tail, existing-key replacement beyond a tombstone, final-probe tombstone
reuse, all-tombstone misses/insertions, zero/all-one keys/values, tag extremes,
420 deterministic mixed commands per profile, reset/reuse and held outputs.
The maximum configuration is actually simulated. Nine illegal parameters
are rejected; all **22** recorded tool invocations passed their intended
outcome, including those expected failures.

Each profile has six reset markers plus seven explicit phase probes, covering
metadata clear, idle, synchronous probe read, probe check, pending PUT write,
pending DELETE and held response. Reset is asserted at the **current observed
boundary**, before another active edge. Every probe checks the full metadata
sweep and a fresh missing-key lookup. The probes are finite cancellation
examples, not exhaustive reset-cycle proofs. No hardware maturity is inferred.
All package text is LF; existing workspace assets and stable refs are untouched.

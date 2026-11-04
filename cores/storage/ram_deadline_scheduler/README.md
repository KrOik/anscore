# Keyed deadline event scheduler in synchronous RAM

`ram_deadline_scheduler` keeps one pending deadline/payload per event ID.
UPSERT inserts or replaces that identity, CANCEL removes it, NEXT inspects the
earliest event, and TAKE claims it only when its deadline is at or before a
captured cutoff. This supports cancelable/reschedulable work and timeouts.
The service computes its own temporal minimum from raw runtime events; the
caller does not supply a sorted queue or minimum certificate.

## Domain and command contract

| Parameter | Default | Legal domain |
|---|---:|---|
| SLOTS | 16 | every integer 1..128, including non-powers of two |
| ID_W | 16 | 1..32 |
| TIME_W | 32 | 1..64 |
| DATA_W | 32 | 1..64 |
| TAG_W | 8 | 1..32 |

IDs, deadlines and cutoffs are exact unsigned integers. Payload and tag are
opaque bit fields. Zero, high-bit and all-one values are legal. Capacity is
the lesser of SLOTS and the number of distinct encoded IDs. There is no
reserved ID, generation field, rounding, timestamp saturation or implicit
tick. Reusing an ID intentionally replaces its pending event; a stale CANCEL
with the same ID can remove a later reuse. The caller owns ID lifetime.

Deadlines and cutoffs are absolute values in one caller-chosen unit/epoch.
Ordering is ordinary unsigned comparison, **not modular wrap-time ordering**.
Already-due deadlines are accepted, equality is due, and independent commands
may use decreasing cutoffs. NEXT does not advance stored time. There is no
autonomous counter, interrupt, periodic resubmission or wall-clock conversion;
the caller supplies a current cutoff when it wants to inspect/claim work.
Use an adequate extended epoch externally when a physical counter can wrap.

| s_op | Action | Relevant source fields |
|---|---|---|
| 0 UPSERT | Insert or replace the unique event ID | s_id, s_deadline, s_data |
| 1 CANCEL | Remove exactly the matching pending ID | s_id |
| 2 NEXT | Return earliest event without removing it | s_cutoff, for due flag |
| 3 TAKE | Remove earliest event only if due | s_cutoff |
| 4 CLEAR | Discard all pending events | geometry/data/cutoff ignored |
| 5..7 | Reject illegal opcode | all event fields ignored |

Earliest means minimum `(deadline, unsigned ID)` lexicographically. Payload,
insertion order and physical slot placement never break deadline ties. A
replacement changes both deadline and payload atomically and can move an event
earlier or later. It succeeds while full because its existing slot is reused.
An absent-ID insertion while full fails without evicting any event. CANCEL
needs no current deadline or payload and does not remove another event.

Every response echoes captured `m_op/m_tag`. The record fields
`m_id/m_deadline/m_data` are the **new** record on successful UPSERT, the removed
record on CANCEL, or the temporal minimum on NEXT/TAKE. `m_found` indicates
that such a record is present in the response. `m_replaced` is one only for
an UPSERT of an existing ID. `m_due` compares the returned deadline with the
captured cutoff only on NEXT/TAKE; it is zero on other operations. Post-command
`m_live/m_free` count exact occupied/free slots in 0..SLOTS. These fields are
transaction snapshots only while valid, not an independent live-status bus.

| m_status | Meaning | Response record and effect |
|---|---|---|
| 0 | Success | As above; NEXT preserves the event |
| 1 EMPTY | NEXT/TAKE has no pending event | found0, zero record; unchanged |
| 2 MISSING | CANCEL ID is absent | found0, zero record; unchanged |
| 3 FULL | Absent-ID UPSERT has no free slot | found0, zero record; unchanged |
| 4 NOT_DUE | TAKE minimum is later than cutoff | found1, earliest record, due0; unchanged |
| 5 BAD_OP | Illegal operation encoding | found0, zero record; unchanged |
| 6..7 | Not generated | - |

CLEAR returns success with found/replaced/due and record all zero. Every
failure with found0 also returns replaced/due and record all zero. A NOT_DUE
response deliberately returns the next deadline so the caller can schedule a
later claim; it does not hide or remove the event. NEXT returns status0 even
when that event is not due. Every event field omitted from the relevant-fields
column is ignored and can contain all-one bits without rejection.

## Clock, backpressure and reset

All ports use one rising-edge clk, ordinary ready/valid and synchronous
active-high rst. There is no external CE, CDC, frame/LAST, runtime parameter
bank or payload-memory interface. Sources hold **valid and all source fields**
until `s_valid && s_ready` or reset. Responses transfer on `m_valid && m_ready`;
valid and every field remain stable under arbitrary sink backpressure. An
accepted command owns the full scan/mutation/response. Another command cannot
transfer on the response-retiring edge and waits for the next idle boundary.
Legacy CE-qualified neighbors need an explicit semantics adapter.

Mutations complete before valid first appears. Response acceptance retires an
already completed operation, with no response-ACK commit or rollback. A caller
should act on a claimed event only after its response transfers. Reset can
cancel an unconsumed claim response and discards the entire pending event set;
the caller must replay the required calendar and discard canceled work.

Asserting rst suppresses public ready/valid immediately. Its active edge clears
control/occupancy and record/flag/tag/op/status outputs to zero (live0/freeN),
and cancels a scan, private write,
partially completed clear or held normal/error response. On the next SLOTS
clocks after release, one RAM row is zeroed per clock before ready. Reset held
high restarts at row zero without array writes. Canceled commands return no
completion. CLEAR performs the same serial erasure with a tagged response.
There is no stale RAM read before the initialization sweep completes.

## Architecture, widths and structural budget

The service stores `{live,ID,deadline,payload}` in one packed synchronous RAM.
Every ordinary operation scans all SLOTS rows using separate synchronous-read
and consume states. UPSERT/CANCEL retain a matching ID; insertion also retains
the first free row. NEXT/TAKE retain the smallest `(deadline,ID)` found so far.
No row becomes visible as an event until its full write completes. A separate
decision stage validates full/missing/empty/not-due conditions; only successful
UPSERT/CANCEL/due-TAKE writes one row. Reset/CLEAR use serial zero writes.

One read port and one write port suffice and are active in disjoint states.
No same-address read-during-write value, asynchronous full-table read, host
pointer, heap, timing wheel, vendor primitive, multiplier/divider, external
memory, generated ROM or initial-memory file is required. The bounded linear
scan trades O(SLOTS) control latency for simple exact replacement/cancellation
and one shared deadline/ID comparison datapath.

Let N=SLOTS, R=ID_W+TIME_W+DATA_W, IW=max(1,clog2 N), CW=clog2(N+1).
IW/CW are internal, not public overrides. Metadata storage is `N*(R+1)` bits:
**1296 default / 20608 maximum bits**. Explicit scalar/control/read/response
storage is `4*R+TIME_W+3*IW+CW+TAG_W+16` bits:
**393 default / 781 maximum bits**. Counts include 0..N exactly; cursor wraps
only by explicit end comparison. All timestamp operations are comparisons,
so no time addition, overflow, half-range ambiguity or signed narrowing is
hidden in the datapath. Illegal static settings fail elaboration through
`ram_deadline_scheduler_invalid_parameters__see_README`.

Budgets are logical declarations, not mapped LUT/FF/BRAM/DSP measurements.
Default resource risk is qualitatively LOW, maximum MEDIUM because of wide
row banking/comparison/routing, physical memory packing and serialized service
time. Tiny tables may map to registers rather than BRAM. No Fmax, power,
physical fit, device compatibility or board-throughput result is claimed.

Acceptance to first response-valid is exactly 2N+2 periods for successful
UPSERT/CANCEL/due-TAKE, 2N+1 for other ordinary scans, N for CLEAR, and zero for
illegal-op rejection. Earliest response transfer is the following edge. The
conservative first-valid bound is **2N+2 = 34 default / 258 maximum cycles**.
Output holds and retirement add to accepted-command intervals; unbounded
backpressure admits no unconditional retirement deadline. The service targets
modest-rate event control rather than one update/claim per cycle.

## Offline closure and fixed finite evidence

`files.f` contains the sole production RTL. `example/files.f` adds `deadline16`,
the default direct ready/valid instance forwarding every field. Both lists are
relative to this directory. Example evidence is syntax/instantiation only.
LICENSE covers original local Apache-2.0 work; SOURCES.md records actual fixed
upstream/full-license inspection and semantic differences. No sibling source,
include, generated data, untracked dependency or network is needed offline.
Package-local `.gitattributes` was created first and enforces LF; package bytes
are UTF-8 without BOM.

```text
iverilog -g2012 -Wall -tnull -s ram_deadline_scheduler -f files.f
iverilog -g2012 -Wall -tnull -s deadline16 -f example/files.f
python -B cores/storage/ram_deadline_scheduler/run_tests.py
```

The Python command runs from the repository root and uses only standard-library
Python plus local Icarus/vvp. TEST_PLAN.json freezes exact five-profile input
hashes/counts, ten static rejections, and 20 reset/fresh targets per profile
before the first HDL child. Profiles cover N1/3/7/16/128 and timestamp widths
1/4/16/32/64, including both default and largest declared event fields. Every
compiler/simulator child has a fixed 20-second limit. A timeout is terminal:
no retry, smaller fixture or larger limit. Ordinary concrete failures retain
original receipts/tested sources before repairing the identical frozen matrix.
Temporary vectors and executables are task-specific and removed automatically.

The independent expected-result oracle is a unique-ID Python dictionary using
minimum `(deadline,ID)`, not the RTL's serial scan or free-slot selection.
Every response field and every RAM row are decoded into a duplicate-free
logical event map and checked. Directed/seeded tests cover replacement while
full, earlier/later replacement, cancellation/reuse, deadline equality and
unsigned high bits/extrema, backdated cutoffs, missing/empty/full/not-due/bad-op,
ignored fields, ID tie break, all-slot fill/refill/drain and all length-three
sequences over eight commands in the one-slot/one-bit profile.

The actual next frozen command is offered while the previous response waits
and remains asserted with all fields unchanged through its own acceptance.
Explicit source-hold checks and exact accepted-command counts prevent dummy
offers from being silently withdrawn. Held output, exact first-valid schedules
and all seven controller states are checked. Reset probes observe a low-clock
target and assert immediately before another active edge, including insert/
replace/cancel/take writes, scan/decision boundaries, partial clear/init and
held success/error/not-due. Held next-command probe offers are canceled by
reset, not withdrawal. Every cancellation completes a fresh UPSERT/NEXT-not-due/
TAKE-at-equality/empty-NEXT recovery with all fields and logical RAM checked.

`verification.json` is authoritative for actual executed status, current
source/input hashes, receipts, counters and any historical attempts. Tests are
finite unit evidence, not all histories/parameter tuples or arbitrary-cycle
formal proof. All hardware is **HW_UNVERIFIED**; synthesis, PnR, STA, board work
and expanded regression are NOT_RUN.

The first fixed five-profile matrix passed all 21 bounded tool records, including
ten expected static-parameter rejections, with no failure, timeout, reduction or
rerun. All 4504 main commands were accepted exactly once and checked at their
exact response-valid schedule. There were 149976 logical slot-image comparisons,
323342 compliant blocked-source holds, and 100 immediate reset cancellations
followed by 400 complete fresh recovery commands. Every profile reached the
maximum first-valid bound: 4/8/16/34/258 cycles. All fields in the N128/64-bit
profile were numerically exercised.

Inclusive trace activity was 436385 nonreset cycles, 323372 blocked-source and
20300 held-response cycles, 196083 row reads, 2683 mutation writes and 5479 row
initialization writes. Source-hold/map/command/latency/semantic coverage is main
traffic; trace access/stall counts include setup, probes and recovery, as scoped
in the receipt. The additional 30 blocked cycles are reset-canceled probe offers.
Current maturity is **LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED**; the default
example has syntax evidence only. This README-only measured-results refresh is
separated in tested/current hash maps; no implementation, test, oracle, plan or
vector changed after qualification and no further numerical run was performed.

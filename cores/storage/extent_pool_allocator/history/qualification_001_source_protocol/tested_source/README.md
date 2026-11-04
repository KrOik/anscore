# Exact contiguous extent ownership in synchronous RAM

`extent_pool_allocator` reserves exactly an arbitrary requested number of
contiguous basic units. The start has a caller-chosen power-of-two alignment;
length is never rounded to that alignment or to a power of two. Hardware finds
the lowest eligible offset from its own current ownership state. Release must
match one whole live base/length allocation. This is useful for packed variable
payload buffers; it stores metadata only. Payload RAM, byte-address conversion,
DMA and access arbitration belong to the caller.

This adds a different ownership capability from `buddy_pool_allocator`:
3/5/7-unit extents consume exactly 3/5/7 units and alignment padding remains
available to later requests. Fixed-cell packet queues and range locks do not
provide this allocator contract.

## Commands and protocol

| Parameter | Default | Legal values |
|---|---:|---|
| UNITS | 64 | every integer 1..256, including non-powers of two |
| TAG_W | 8 | 1..32 |

Offsets and lengths are unsigned counts of caller-chosen basic units, not
bytes. The pool is `[0,N)` with N=UNITS. The fixed 32-bit base/length ports are
validated before narrowing; derived IW=max(1,clog2 N) and CW=clog2(N+1) are
local implementation widths. Free and largest-gap outputs are CW-bit counts
0..N. Illegal static parameters fail elaboration through
`extent_pool_allocator_invalid_parameters__see_README`.

All ports share one rising-edge clock. Reset is synchronous active high; there
is no external CE, CDC, configuration bank, frame/LAST or external memory port.
Commands transfer on `s_valid && s_ready`. The source holds valid and all fields
until transfer. One command owns the service through its held response: no
next command is accepted during scanning, mutation, summary or response hold.
Responses transfer on `m_valid && m_ready`; every field remains stable under
arbitrary backpressure. There is no same-edge retirement/admission fallthrough.

| s_op | Action | Relevant geometry |
|---|---|---|
| 0 | Allocate lowest-address eligible free extent | s_length, s_align_order; s_base ignored |
| 1 | Release exactly one live allocation | s_base, s_length; s_align_order ignored |
| 2 | Query free-space summary | all geometry ignored |
| 3 | Clear all ownership | all geometry ignored |
| 4..7 | Reject illegal opcode | geometry ignored; never changes ownership |

Allocation requires `1<=s_length<=N` and `0<=s_align_order<=8`; base is a
multiple of `2^s_align_order`. Alignment can exceed the pool size: offset zero
is still eligible. An aligned start does not require an aligned end. The
returned range is `[m_base,m_base+s_length)` with exactly s_length owned units.
No best-fit/LIFO ordering, relocation, implicit eviction or payload header is
used. A request can fail from fragmentation or alignment even if total free
space is at least its length.

Release requires `1<=length<=N`, `base<N`, `base+length<=N` using a 33-bit sum,
and an exact live allocation with that base and length. Interior, wrong-size,
combined-adjacent, double, high-bit and overflowing releases cannot free any
ownership. Alignment is not part of allocation identity and is ignored on
release, including encoded orders 9..15. No generation is supplied: a stale
base/length pair can release a later allocation with the same pair. The caller
owns identifier lifetime and must prevent stale releases after reuse/reset.

Every response echoes captured `m_op/m_length/m_align_order/m_tag`, including
ignored fields and errors. `m_base` is the successfully allocated or released
offset; it is canonically zero for queries, clear and every failure.
`m_free_units` is the post-command total number of free units;
`m_largest_gap` is the longest contiguous free run without alignment filtering.
The latter is zero for a full pool and N for an empty pool. Adjacent separately
allocated extents remain separate identities until individually released.

| m_status | Meaning | Effect |
|---|---|---|
| 0 | Success | Complete requested mutation, or unchanged query |
| 1 | Bad relevant length/alignment/release geometry | No mutation |
| 2 | No eligible allocation extent | No mutation |
| 3 | Geometrically valid release has no exact live identity | No mutation |
| 4 | Illegal opcode | No mutation |
| 5..7 | Not generated | - |

Mutations complete before response presentation. Response acceptance retires
an already completed command; this is not response-ACK commit or rollback.
Computation and mutation are private while ready is low. Output fields outside
valid have no command-snapshot meaning.

## Reset, architecture and bounds

Asserting rst immediately suppresses public ready/valid. Its active edge
cancels any scan, partially applied allocation/release/clear or held normal/
error response. On the next N clocks after reset release, initialization clears
one metadata row per clock and admits no commands; no canceled or earlier
ownership survives this sweep. Reset held high restarts the controller at row
zero without array writes. Reset returns no completion; CLEAR performs the
same serial ownership erasure but returns the command's tagged response.
Neither operation clears payload memory. Payload users must be quiesced when
discarding ownership and must re-establish any required allocation decisions.

One packed synchronous RAM row per unit holds `{busy,head_length}`. A live
allocation has its full CW-bit length only at its start; interior busy rows
have zero length, and free rows are all zero. Allocation scans increasing
offsets, starts a candidate only at an aligned free unit, and tracks the free
run until length is met. It writes exactly that span. Release synchronously
reads the proposed start, validates busy plus exact head length, then writes
the span free. A separate serial summary scan counts free units and longest
run. There is no coalescing metadata to repair: neighboring free rows naturally
form one contiguous run on the next scan.

RAM has one synchronous read port and one write port, scheduled in disjoint
states with no read-during-write collision dependence. Initialization uses
serial writes rather than parallel array reset. Read data is not reset and is
overwritten by a current-command read before consumption. There is no complete
array combinational read, multiplier, divider, vendor primitive, generated
initial contents or third-party runtime dependency. Long scan work is traded
for small bounded control and a single narrow row datapath.

Metadata storage is `N*(CW+1)` bits: **512 bits** at default N64, **2560 bits**
at maximum N256. Scalar/control/response declarations total
`81+TAG_W+3*IW+9*CW` bits: **170 bits** default and **218 bits** maximum.
This is a logical declaration budget, excluding combinational wires and
unmeasured tool mapping. Tiny arrays may become registers rather than BRAM.
Resource risk is qualitatively LOW default / MEDIUM maximum due to scan
latency, routing and memory inference. LUT/FF/BRAM/DSP, Fmax, power, physical
fit and board throughput are unmeasured.

Acceptance to response-valid is bounded by `5*N+8` periods (328 default,
1288 maximum), including at most 2N allocation read/check clocks, N mutation
clocks and 2N summary clocks plus control. Clear takes N periods; query and
early rejection take 2N periods. Release has one read/check pair, at most N
mutation clocks and 2N summary clocks. An output transfer can occur on the
edge after valid first appears. Command interval also includes response hold
and retirement; unbounded backpressure admits no finite retirement deadline.
This targets modest-rate buffer control, not one allocation per cycle.

## Offline use and finite checks

`files.f` lists the sole production source. `example/files.f` additionally
lists the default 64-unit `extent_pool64` port-forwarding instance. Both lists
are relative to this package root. The example supplies syntax/instantiation
evidence only; it does not connect payload memory or establish a verified DMA
system. Local LICENSE covers original work, with upstream preflight and
semantic distinction in SOURCES.md. No siblings, includes, generated tables,
ROM data, untracked files or network access are needed for production use.

```text
iverilog -g2012 -Wall -tnull -s extent_pool_allocator -f files.f
iverilog -g2012 -Wall -tnull -s extent_pool64 -f example/files.f
python -B cores/storage/extent_pool_allocator/run_tests.py
```

The Python command uses only standard-library Python and local Icarus/vvp.
TEST_PLAN.json freezes all five profiles N/T=1/1,3/3,17/8,64/8,256/32, exact
input hashes/counts, four illegal static settings, and 16 immediate reset
targets per profile before the first HDL tool. Every compiler/simulator child
has a fixed 20-second limit. A timeout is terminal for the frozen batch;
ordinary failures are archived before fixing the unchanged finite matrix.
Temporary vectors/executables are task-specific and removed automatically.
No successful matrix is automatically rerun.

The expected-result oracle maintains sorted live geometric intervals and
computes their complementary gaps, independently of the RTL's per-unit scan.
Every response field and every unit's busy/head-length image are compared.
Directed tests cover exact odd lengths, alignment padding reuse, whole-pool
and single-unit exhaustion, alternating fragmentation, fully restored large
ranges, exact/wrong/interior/combined/double releases, all full-width geometry
and opcode errors, ignored fields and seeded persistent traffic. N1 also
exhausts all length-three sequences over an eight-command alphabet. Protocol
checks cover accepted-field capture, blocked next-command offers, output
hold, all ten controller states and the fixed latency bound.

Reset is asserted at the target observation without another active edge,
including allocation first/middle/last writes, release middle writes, partial clear/init,
scan and summary boundaries, release-head reads and held success/error.
Every cancellation is followed by a fresh complete whole-pool allocate/query/
release/query sequence and independent metadata checks. This is finite unit
evidence, not arbitrary-cycle formal proof or exhaustive parameter coverage.
Actual executed status, tool receipts, source/vector hashes, counts and any
archived ordinary failures are in verification.json. All hardware remains
**HW_UNVERIFIED**. No synthesis, PnR, STA, board work or expanded regression is
part of this package's qualification.

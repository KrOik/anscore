# Variable-size buddy address pool service

`buddy_pool_allocator` manages a fixed range of basic-unit offsets and returns
exclusive, aligned power-of-two blocks. It stores only allocation metadata;
the caller owns the actual payload RAM, byte-address conversion and access
arbitration. Allocate, exact release, clear and free-space query are complete
hardware commands. No allocation layout, free list or address is precomputed
by the host.

## Command and response contract

All ports share one rising-edge clock, ordinary ready/valid and synchronous
active-high `rst`. There is no CE, CDC, frame protocol or external memory port.
One `s_valid && s_ready` atomically captures op/order/base/tag. The source holds
all fields until that handshake. Only one command is in flight; input ready
stays low through computation and the held response. All response fields remain
stable while `m_valid && !m_ready`; admission resumes after response retirement.
Output fields outside valid have no transaction meaning.

Offsets are unsigned **basic units**, not bytes. The pool contains
`U=2^MAX_ORDER` units at offsets `[0,U)`. An order o block covers
`[base,base+2^o)` and base must be a multiple of `2^o`. A basic unit can represent
a byte, a payload word or a larger caller-chosen quantum. Choosing a larger
quantum changes the caller's address conversion, not this service's metadata.

| `s_op` | Action | Relevant fields |
| --- | --- | --- |
| 0 allocate | Reserve the lowest-address currently free aligned block of size `2^s_order` | order; base ignored |
| 1 release | Release exactly one live allocation with matching base and order | order, base |
| 2 clear | Discard every allocation and restore the entire free pool | order/base ignored |
| 3 query | Return free-space summary without changing ownership | order/base ignored |

`m_op`, `m_order` and `m_tag` echo the captured fields on every response,
including errors and ignored order fields. `m_base` is the allocated offset or
successfully released offset; it is zero for every failure, clear and query.
Tag width does not affect allocation identity.

| `m_status` | Meaning and effect |
| --- | --- |
| 0 | Success |
| 1 | Allocate has no eligible block; no mutation |
| 2 | Bad order (`s_order>MAX_ORDER`), or release base outside the pool / misaligned for that order; no mutation |
| 3 | Geometrically legal release does not exactly match a live base/order allocation; no mutation |

An allocation can fail from fragmentation even when enough individual units
remain free. A legal interior address, wrong order, or duplicate release is
rejected rather than releasing adjacent/current ownership. No payload header
is read and no allocation is evicted. Blocks may be released in any order;
fully free buddies merge recursively so a fully released pool supports one
whole-pool allocation again. Allocation selection is deterministic lowest
address, not a software allocator's free-list/LIFO ordering.

There is no generation field: after a base/order has been released and reused,
a stale release with that same pair is indistinguishable from a current release.
The caller must prevent stale releases, including after reset/clear. This is
an address-ownership service, not a capability or protection mechanism.

Every response includes the **post-command** `m_free_units` (0..U),
`m_has_free` and `m_largest_order`. When `m_has_free=1`, the latter is the largest
order for which an allocation could currently succeed. If the pool is full,
`m_has_free=0` and largest order is canonically zero. Error/query responses give
the unchanged summary. The total free count alone does not imply a particular
block can be allocated.

Reset immediately suppresses public ready/valid, and its active edge cancels
any partial mutation or held response, resets the counter and makes the root
fully free. The entire old pool ownership is discarded, including earlier
successful commands; canceled commands produce no response. The caller must
quiesce payload users and replay ownership decisions as appropriate. Clear has
the same logical ownership effect but returns a tagged response. Neither action
clears payload memory or promises payload confidentiality.

## Parameters, serialized tree and resource boundary

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `MAX_ORDER` | 6 | 0..10 inclusive; order 0 is a one-unit pool |
| `TAG_W` | 8 | 1..32 |

The order input is always unsigned 4-bit and the base input/output unsigned
32-bit, permitting explicit encoded out-of-range command checks. The free-unit
count is `MAX_ORDER+1` bits. Illegal static parameters fail elaboration through
an unresolved `buddy_pool_allocator_invalid_parameter__see_README` instance.
Derived address/count widths are local, not overridable user parameters.

A complete breadth-first binary tree uses `2*U-1` entries. Each stores two state
bits (FREE / ALLOC / SPLIT) and `OW=max(1,ceil(log2(MAX_ORDER+2)))` summary bits.
Summary zero means no available block; nonzero means largest free order plus
one. Free roots hide all descendants. Before a FREE node becomes SPLIT, both
children are explicitly initialized, and no child is read until this completes.
Thus reset/clear writes just the root; the array and inactive descendants do
not need reset or an initialization file. A release must traverse SPLIT ancestors
and find an ALLOC target; stale descendants beneath FREE or ALLOC nodes cannot
validate a release.

Allocation follows child summaries, choosing the left eligible child first;
free blocks split until the requested order. Release follows address bits.
After the target write, both children of each ancestor are synchronously read,
then one parent is written with their merged state and maximum availability.
One synchronous read port and one write port suffice. The controller serializes
all accesses; no cross-port collision value or read-during-write mode is relied
on. Ownership becomes externally reviewable only in its completed response.

There is no full-pool scan, associative data comparison, payload RAM, multiplier,
divider, vendor primitive or external storage. Metadata is **635 bits** at the
64-unit default and **12,282 bits** at the 1024-unit maximum, plus bounded control
and response registers. Tiny pools may map to registers rather than RAM; actual
memory mapping is unmeasured. Qualitative resource risk is **LOW** by default,
**MEDIUM** at maximum because of metadata addressing/muxing and synthesis memory
mapping. No measured LUT/FF/BRAM count, Fmax, power or device fit is claimed.

From command acceptance to response valid, clear takes one period and query or
initial bad-request rejection takes two. Other paths are variable, bounded by
`12*(MAX_ORDER+1)+8` clock periods; the bound includes splitting, descent and
ancestor repair. Earliest output transfer is one edge after valid. Backpressure
adds arbitrary residence time, so there is no unconditional retirement deadline.
This deliberately serialized service targets modest-rate buffer ownership,
not one allocation per cycle or a measured hardware throughput.

## Offline use and finite evidence

`files.f` lists the one production source. `example/files.f` adds the default
64-unit wrapper, forwarding every command, summary and status signal. Both
manifests are relative to this package root. The example does not instantiate
payload memory or imply a DMA connection. No sibling, untracked, include,
generated ROM, network or third-party runtime dependency is required. The
package's LICENSE is Apache-2.0 for the original local work.

```text
iverilog -g2012 -Wall -tnull -s buddy_pool_allocator -f files.f
iverilog -g2012 -Wall -tnull -s pool64_example -f example/files.f
python -B cores/storage/buddy_pool_allocator/run_tests.py
```

The Python command runs from the repository root; each subprocess has a
20-second limit. Only local Icarus/vvp and Python's standard library are used;
task temporary vectors and executables are automatically removed. Source and
vector SHA256s, actual commands and results are recorded in `verification.json`.
All package text uses LF.

Five profiles cover max orders 0/1/3/6/10 and tag widths 1/3/8/8/32. The independent
oracle is a set of live geometric intervals: it enumerates aligned candidates
and checks overlap, without the RTL's tree, split, child-summary or parent
traversal algorithm. Every response field and an independent occupied-unit /
allocation-start snapshot are checked. A TB traversal checks only reachable
metadata, complete unit ownership, exact allocation boundaries, summaries and
absence of unmerged FREE buddies. These structural checks supplement the
independent functional oracle; they do not derive expected addresses from RTL.

Fixtures include whole-pool and minimum-block exhaustion, alternating holes,
fragmentation failure, full coalescing, every aligned release base/order against
empty/full ownership, wrong-order/interior/double/out-of-range frees, ignored
geometry on clear/query, persistent seeded traffic and exhaustive length-three
command sequences on the one/two-unit pools. Output stalls, source-field
capture, actual blocked next-command offers and tags are checked. Reset_now is
asserted immediately at each reachable controller-state boundary, including
split/update writes and held output, without another edge. The one-unit pool
has seven reachable states; larger profiles exercise all sixteen. Four illegal
static settings and the default example syntax are explicitly checked.

Recorded evidence supports **LINT_PASS + UNIT_SIM_PASS**, with the wrapper
**INTEGRATION_CANDIDATE** by syntax compilation only; all RTL is
**HW_UNVERIFIED**. No synthesis, PnR, STA, board test or expanded regression ran.
Finite tests do not exhaust all traffic histories or legal parameter tuples.

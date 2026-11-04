# Shared-cell packet queues

`shared_packet_queues` stores complete variable-length packets in several
independent FIFO queues backed by one dynamically shared cell pool. It combines
payload storage, provisional packet ownership, atomic publication, packet
selection and credit reclamation. A queue can use the entire pool; capacity is
not divided into equal per-queue banks. There is no host-provided linked list,
external RAM, descriptor allocator or precomputed packet layout.

## Commands and packet ownership

All signals share one rising-edge clock and ordinary ready/valid. `rst` is
synchronous active high. There is no CE, CDC or external memory bus. The source
holds every field while `s_valid && !s_ready`. Input transfers on
`s_valid && s_ready`; output transfers on `m_valid && m_ready`.

| First `s_op` | Command | Input ownership |
| --- | --- | --- |
| 0 PUSH | Store one packet in `s_queue` | First accepted beat owns queue/tag; subsequent op/queue/tag ignored; accepted `s_last` closes packet |
| 1 POP | Replay and remove one oldest packet from `s_queue` | Exactly one command beat; data/keep/last ignored |
| 2 FLUSH | Drop all committed packets of `s_queue` and reclaim their cells | Exactly one command beat; data/keep/last ignored |
| 3 QUERY | Return selected queue occupancy and global free credit | Exactly one command beat; data/keep/last ignored |

PUSH keeps one unsigned DATA_W-bit word for each accepted `s_keep=1`.
Masked beats consume no cell, including first/tail beats. The first accepted
beat owns its tag and queue even if masked. Packets must contain at least one
kept word; an all-masked packet returns EMPTY and is not enqueued. A tail can
be masked: commit explicitly marks the last retained word as packet end.
A packet missing its accepted tail holds the service indefinitely until reset;
there is no timeout, forced tail or service preemption.

PUSH reserves free cells privately while collecting. It does not change any
committed queue until the complete packet fits and closes. If a kept word
cannot get a free cell, the rest of that packet drains through its tail,
without further payload allocation. Every provisional cell is then reclaimed
and NO_SPACE is returned. The whole new packet is rejected; all earlier
committed queues and packets survive, including earlier packets in the same
queue. Invalid first queue IDs also drain a PUSH through its tail, without
allocating cells. Later queue IDs/op/tag never redirect or validate a packet.
There is no prefix publication, eviction or stealing another queue's cells.

POP selects a queue explicitly; there is no automatic arbiter or scheduling
policy. It returns every word of that queue's oldest complete packet in order,
then stops at its packet-end marker. Neighboring queued packets remain stored.
FLUSH is accepted only when no PUSH, POP or other command is active, so it
never publishes, edits or flushes a partially collected packet. It reclaims
exactly the selected queue's committed cells, preserving all other queues.

Only one command is in flight. Ready is low during cell access/reclamation,
POP replay and held response. A caller may pre-offer its next command and must
hold it until accepted. The final response token must retire before another
command can transfer. All internal computation advances without input valid
or output ready, except held POP/ACK retirement. There is no concurrent queue
producer/consumer operation or guaranteed fairness between callers.

## Responses, errors and credit timing

`m_op`, unsigned 8-bit `m_queue` and `m_tag` echo the command's first metadata.
A successful nonempty POP returns `m_keep=1`, the stored `m_data`, the original
PUSH tag in `m_packet_tag`, a zero-based word index, and first/last markers.
The request tag and packet tag are separate. All words of one packet have the
same packet tag. Other commands, empty POP and errors return one masked token:
data/packet_tag/index are zero, first and last are one.

| `m_status` | Meaning |
| --- | --- |
| 0 OK | PUSH committed, POP data, FLUSH completed or QUERY succeeded |
| 1 EMPTY | PUSH has no kept words, or selected POP queue is empty |
| 2 BAD_QUEUE | First unsigned queue ID is >= QUEUES; no queue mutation |
| 3 NO_SPACE | PUSH cannot fit completely; every provisional cell rolled back |

Invalid queue takes precedence over space/empty status. A full pool still
accepts a masked-only PUSH and reports EMPTY. Non-PUSH commands ignore keep,
last and payload even when those fields would not describe a packet. Queue
count/packet count are zero on BAD_QUEUE; global credit remains diagnostic.

Every response supplies `m_free_cells`, `m_queue_cells` and `m_queue_packets`.
For an ACK/status token these describe the completed command. For POP data
these describe state **immediately after that token's handshake**, not after
the entire packet. Its cell remains owned by the queue and excluded from the
free list throughout any output stall. The handshake atomically returns one
cell, advances queue head and decrements queued cells; queued packet count
falls only on the final word. A displayed future credit must only be used
when that output token transfers. The core admits no other command meanwhile.
This convention also means an early POP word can report a remaining packet
count that still includes its partially replayed packet.

Valid and every output field remain stable through arbitrary backpressure.
Invalid output fields have no transaction meaning. A queue with zero cells
has zero packets; every committed packet contains at least one cell. Counts
include a held POP word until its handshake. No cell address is exposed and
no allocation-generation or external ownership handle is required.

## Reset and serialized memory schedule

Reset gates public ready/valid low immediately; its active edge cancels the
current command, pending packet and held output and discards **all queues**.
It also discards previously committed packets, regardless of which queue was
active. No cancellation or drop token is emitted. Hold reset across a rising
edge. After deassertion, CELLS rising edges rebuild the free-link chain before
ready returns. A new reset restarts this initialization. Payload and marker
arrays are not cleared: each cell is overwritten before becoming newly live.
The caller must replay any canceled traffic it still needs. Reset is not a
payload-erasure or confidentiality guarantee.

Cell payload/tag, next link and packet-end marker use synchronous reads.
The single link read/write schedule never relies on read-during-write values.
A PUSH word first reads the free head's next link, then overwrites/removes that
cell from the free list, then links the previous provisional tail to it.
Only after the link step can collection resume. COMMIT marks the provisional
tail as packet end and appends the chain to the selected queue; the old queue
tail's existing packet-end flag stays set. Partial updates are private to the
single-command controller. Reset reconstructs the entire ownership partition.

POP registers the queued head's data/link/marker, holds ownership until its
output handshake, then links the consumed cell onto the free list. Rollback
and FLUSH synchronously read each reclaimed link before overwriting it with
the free head. Reclamation counts bound every walk; inactive pointers and
unused payload bits cannot validate an allocation or generate output.

| Event | Periods until first response valid |
| --- | ---: |
| Successful PUSH with retained tail | 4 after accepted tail |
| Successful PUSH with masked tail | 1 after accepted tail |
| EMPTY PUSH or BAD_QUEUE PUSH | 0 after accepted tail |
| NO_SPACE PUSH | 2*P after accepted tail, where P is its allocated provisional prefix length |
| Nonempty POP | 1 after its command beat |
| FLUSH | 2*L after its command beat, where L is selected queued cell count |
| QUERY, empty POP, invalid non-PUSH | 0 after command beat |

A retained PUSH beat permits the next input at E+4; masked/drain beats can
transfer on consecutive edges. After a nonfinal POP transfer, next valid
returns one period later; always-ready POP transfers are two periods apart.
Earliest transfer is one rising edge after valid. Source gaps, missing tail
and output stalls imply no unconditional wall-clock completion deadline.
These are controller schedules, not measured frequency/line-rate claims.

## Parameters, resource risk and offline use

| Parameter | Default | Legal values |
| --- | ---: | --- |
| QUEUES | 4 | 1..16, including nonpowers of two |
| CELLS | 64 | 1..256, including nonpowers of two |
| DATA_W | 32 | 1..64 unsigned bits |
| TAG_W | 8 | 1..32 |

Queue input/output IDs are always unsigned 8-bit so out-of-range IDs can be
explicitly rejected. Internal indices use IW=max(1,ceil(log2(CELLS))),
QW=max(1,ceil(log2(QUEUES))) and counts CW=ceil(log2(CELLS+1)); legal singleton
pools/queues have nonzero widths. All derived widths are local. Illegal
parameters fail elaboration through the unresolved
`shared_packet_queues_invalid_parameter__see_README` instance.

Cell storage is `CELLS*(DATA_W+TAG_W+IW+1)` bits: 3,008 at defaults and 26,880
at maximum. Small per-queue head/tail/count registers add
`QUEUES*(2*IW+2*CW)` bits: 104 / 544. Scalar controller/read/output registers
are additional. There is no multiplicative QUEUES*CELLS payload duplication,
combinational pool scan, payload reset, multiplier, divider, vendor primitive,
external memory or generated initialization file. The small queue register
arrays have selected-index access. A synthesis tool may pack or implement
small marker/link arrays differently; actual RAM/DSP/LUT/FF mapping, Fmax,
power and device fit are unmeasured. Qualitative resource risk is **LOW** at
default and **MEDIUM** at maximum. Serialization trades throughput for ports
and ownership simplicity; no per-queue reservation or fairness is claimed.

`files.f` contains the one local production module; `example/files.f` adds the
default packet_pool4 wrapper exposing every port. Both are relative to this
package root. There are no sibling/untracked/third-party RTL dependencies.
The included Apache-2.0 LICENSE permits standalone offline use of the original
local contribution. The example is a syntax-only instantiation, not a DMA or
network pipeline.

```text
iverilog -g2012 -Wall -tnull -s shared_packet_queues -f files.f
iverilog -g2012 -Wall -tnull -s packet_pool4 -f example/files.f
python -B cores/storage/shared_packet_queues/run_tests.py
```

Run Python from the repository root. Only standard-library Python and local
Icarus/vvp are used. Each child has a 20-second timeout. Task temporary vectors,
snapshots and simulator images are automatically removed. Source and vector
SHA256s and actual tool records are in `verification.json`; all text is UTF-8/LF.

The independent oracle stores lists of complete packets for each queue; no
physical cell index, free-list ordering or RTL walk is modeled. It predicts
all fields and post-token credit snapshots. The TB separately compares exact
queued payload/packet boundaries against independent queue snapshots and
walks every live/free cell, rejecting aliasing, lost cells, wrong counts and
wrong tails. At stable COLLECT/DRAIN boundaries it also checks provisional
payload against accepted input words and proves provisional+queued+free covers
the entire pool. During held POP it checks the current RAM cell is still the
queue head and excluded from free ownership. ACK holds check the partition;
completed commands check every queue's independent contents. These are finite
canonical-boundary checks, not an arbitrary-clock ownership proof.

Five profiles are Q/C/D/T=1/1/1/1,3/3/5/3,2/8/8/8,4/64/32/8,16/256/64/32.
Fixtures cover complete-pool/partial rollback, neighbor preservation, exact
capacity, full and empty queues, all queue IDs, illegal IDs, packet FIFO order,
masked first/tail metadata, disturbed later metadata, selected FLUSH and
seeded persistent traffic. Singleton length-three and three-cell length-two
command alphabets are exhaustively enumerated. Every output field and exact
first/inter-token valid schedule is checked. Continuous independent drivers
create real source stalls and hold every result for three active clocks.

Immediate reset probes cover all thirteen controller states, rollback and
FLUSH reclamation separately, and a partially consumed POP when capacity
exceeds one. A held result cancels a pre-offered next command. Reset asserts
at the observed phase boundary without another active edge. Eight illegal
static settings must be rejected. Finite results support **LINT_PASS +
UNIT_SIM_PASS**, with the example **INTEGRATION_CANDIDATE** by syntax only;
all hardware behavior remains **HW_UNVERIFIED**. No synthesis, PnR, STA, board
or expanded regression has run, and no legal-parameter/traffic theorem is
claimed.

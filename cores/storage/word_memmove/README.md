# Overlap-safe word memmove

`word_memmove` copies a block of 32-bit words through the acknowledged ANSCORE
native memory transaction port. It preserves the original source contents when
the source and destination overlap: it copies backward when the destination
starts inside the source at a higher address, and forward otherwise. This adds
overlap-safe movement to the existing descriptor-chain DMA, which rejects
nonidentical overlapping ranges.

## Command and completion contract

All core ports use one rising-edge `clk`. `rst` is synchronous active high,
has priority over all transfers, and gates command-ready, request-valid,
response-ready and completion-valid low while asserted. Reset cancels local
work. Reset the memory responder and intervening arbiter as well, or externally
drain/discard orphan responses before reuse. Memory writes already performed
remain performed; reset does not roll back a move.

There is no CE. Every `valid && ready` edge transfers. CE-qualified ANSCORE
interfaces require a semantics adapter. The command source holds `s_valid`,
`s_source`, `s_destination`, `s_words` and `s_tag` stable until accepted.
The core captures every field on `s_valid && s_ready` and accepts only one
command at a time.

`s_source` and `s_destination` are unsigned 32-bit **byte addresses**. Every
access is one complete 32-bit word; no subword byte
permutation, signed interpretation or fixed-point format is imposed. For a
nonempty move, both addresses must be divisible by four and the final addressed
word of each range must fit in 32-bit address space. A single final word at
`0xfffffffc` is valid. Parameters are the only configuration and take effect
at elaboration.

`s_words=0` is a successful no-op, even if its unused addresses are unaligned.
A nonzero same-source/destination move is also a no-op after alignment/range
validation. Both no-op cases issue no memory transactions and report zero
acknowledged writes. A valid range need not be within the responder's actual
memory: backend bounds/access failures return the corresponding read/write
status. All command processing is bounded by the captured word count, except
that a nonresponsive peer may stall indefinitely.

`done_valid && done_ready` consumes one completion. Completion fields and VALID
remain stable while stalled; no next command or memory work starts until it is
acknowledged. One completion covers the complete move, so no frame/LAST marker
is used. `done_tag` echoes the accepted tag. The other fields are:

| Field | Meaning when completion is valid |
| --- | --- |
| `done_status=0` | Success, including no-op |
| `done_status=1` | Invalid alignment or overflowing 32-bit range; no memory transaction issued |
| `done_status=2` | Read response error; no write issued for that failed read |
| `done_status=3` | Write response error |
| `done_words` | Number of writes with successful responses before completion |
| `done_backward` | Backward order was selected for a non-no-op command; zero for rejected/no-op commands |

On failure, earlier acknowledged writes are not undone. A write responder may
have modified memory before returning an error; `done_words` excludes that
failed acknowledgement and is not a rollback or byte-level commit certificate.
For a backward move, acknowledged words form a suffix of the destination range;
for a forward move they form a prefix. The source buffer and destination range
must be owned by the caller throughout the move. Concurrent modification by
other masters is outside the snapshot-preservation contract. Disjoint memory
accesses may be arbitrated concurrently.

## Native memory port

`mem_req_valid && mem_req_ready` transfers a request. `mem_req_write=0` reads
`mem_req_address`; `mem_req_write=1` writes `mem_req_data` at that byte address
with `mem_req_strobe=4'b1111`. Read data/strobe request fields are unused by the
backend. Every exposed request and all fields hold stable under backpressure.
Exactly one request is outstanding. The backend returns exactly one response
per accepted request and holds response data/error/VALID until accepted.

`mem_resp_valid && mem_resp_ready` accepts the response. Read data is captured
only for a successful read; write response data is ignored. A read response
must be accepted before its matching write is issued, and that write response
must be accepted before the next read. There are no IDs, bursts, partial
writes, external descriptors or CDC structures. The peer can stall each
request or response. No autonomous timeout or transaction abort is supplied.
Reset is the coordinated recovery mechanism for a permanently stopped peer.

With requests accepted immediately and responses available on the next edge,
each moved word takes four clocks after command acceptance: read request,
read response, write request, write response. A length-N move accepted on edge
E exposes completion after E+4N and can transfer that completion on E+4N+1.
Backpressure extends this schedule. No-op/rejected commands expose a registered
completion immediately after their acceptance edge. These are RTL scheduling
properties rather than measured hardware bandwidth.

## Parameters, structure and source closure

| Parameter | Legal values | Default |
| --- | --- | --- |
| `COUNT_W` | 1..24; count range 0..2**COUNT_W-1 | 16 |
| `TAG_W` | 1..32 | 8 |

Illegal parameters fail elaboration with a named parameter-error module. The
engine holds one data word, two byte address pointers, a remaining count and
completion state. It uses no internal payload array, ROM, multiplier, DSP,
vendor primitive or external initialization data. Extent validation uses
33-bit arithmetic before addresses are narrowed. The default architecture has
**LOW** qualitative resource risk. At maximum parameters the command extent
addition/comparison/initial-pointer selection path has **MEDIUM** timing risk
until mapped. The engine itself does not allocate storage proportional to move
length. These are structural assessments, not measured resources or frequency.

From this package directory, compile the standalone core with:

```text
iverilog -g2012 -Wall -tnull -s word_memmove -f files.f
```

`files.f` is its complete production dependency closure. The concrete combination
`examples/memmove_scratchpad.sv` joins the core with the existing native
`mem_port_arbiter4` and `mem_port_bram`, exposing a host load/readback port.
Compile it from the same package directory with:

```text
iverilog -g2012 -Wall -tnull -s memmove_scratchpad -f examples/files.f
```

The example dependency list retains relative references to
`../buffer_dma/rtl/mem_port_arbiter4.v` and `../buffer_dma/rtl/mem_port_bram.v`;
include those files when relocating the example. No downloaded sources are
needed. `RAM_DEPTH` follows the existing BRAM's legal power-of-two >=2 range
(default 256). Its default payload is 8,192 logical memory bits; actual mapping
is unmeasured for this combination. The wrapper feeds the existing peers
active-low reset using `!rst`; their asynchronous reset assertion and the core's
synchronous reset must be coordinated with the host master. Reused RAM contents
survive reset and must be initialized by the host before reading them.

## Finite verification

From the repository root:

```text
python -B cores/storage/word_memmove/check.py
```

The runner prefers the local repository OSS CAD Suite and supports `IVERILOG`
and `VVP` overrides. Each subprocess is limited to 20 seconds. Generated
descriptors, snapshots and simulator images live in a task-specific temporary
directory and are deleted on exit. `verification.json` retains real command
results, source hashes, reused-source hashes and regeneration-vector hashes.
Package-local LF attributes preserve source hashes through Git normalization.

The Python oracle copies values from an immutable pre-command source snapshot,
which independently detects corruption from an incorrect overlap direction.
Full final memory, completion status/progress/direction and exact request counts
are compared. COUNT_W/TAG_W profiles 1/1, 4/4, 16/8 and 24/32 each exercise 89
descriptors and compare all 128 backend words per descriptor (45,568 words in
total). Tests include both overlap directions, zero/same-address no-ops,
alignment/range and backend access errors, the last 32-bit word address,
request stalls/stability, delayed read/write responses, injected errors at
different move positions, captured-command mutation, held completion and five
coordinated reset points per profile. Four illegal parameter settings fail
elaboration as expected.

The concrete arbiter/BRAM connection also passes a 15-word backward overlapping
move with all 32 words read back by the host, plus four concurrent host reads
from a disjoint address. Original shared RTL is unchanged; its current exact
sources are separately hashed. These are limited unit/connection checks.

Current maturity: **LINT_PASS** (Icarus syntax/elaboration), **UNIT_SIM_PASS**,
**INTEGRATION_CANDIDATE**, **HW_UNVERIFIED**. Synthesis, PnR, STA, full regression
and board checks were NOT_RUN. Historical evidence for reused modules does not
qualify this new combination. See `SOURCES.md` for semantic and license review.

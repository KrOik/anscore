# Native-port write-back word cache

`word_writeback_cache` caches ordinary 32-bit RAM behind the acknowledged
ANSCORE native memory port. Read and byte-write hits avoid the backend; misses
allocate a whole line, and dirty conflicts write back the old line before
refilling. A flush command writes dirty lines and invalidates every line.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Only the bounded checks below have run. No synthesis, PnR, STA or board test
was performed. This is an original Apache-2.0 contribution; see `SOURCES.md`
for semantic de-duplication, external read-only preflight and local licensing.

## Parameters and representation

| Parameter | Default | Legal range |
|---|---:|---|
| `LINES` | 16 | Power of two, 1 through 64 |
| `LINE_WORDS` | 4 | Power of two, 1 through 16 |
| `TAG_W` | 8 | Command correlation tag width, 1 through 32 |

Illegal parameters deliberately fail elaboration. All addresses are unsigned
32-bit **byte addresses**. Read and write commands require alignment to four
bytes; the cache does not truncate misaligned addresses. `c_data`/`r_data` are
raw 32-bit words without signed or fixed-point interpretation. `c_strobe[b]`
selects bits `8*b +: 8`; no endian conversion occurs.

There are no runtime configuration registers. The address chooses the slot
as `(address / (4*LINE_WORDS)) mod LINES` and the word as
`(address / 4) mod LINE_WORDS`. The remaining upper address bits form the
memory tag. `TAG_W` controls the independent request/response correlation tag,
not the memory tag. All aligned addresses, including `0xfffffffc`, are
representable. Aligned power-of-two lines do not cross the 32-bit address limit.

## Clock, reset and handshake

Every core port uses `clk`. `rst` is synchronous high and must span a rising
edge. There is **no CE**. Input acceptance is `c_valid && c_ready`; response
acceptance is `r_valid && r_ready`. The source holds its complete command
until acceptance. The core accepts one command at a time, in order, and holds
response data, status, hit indication and tag stable under backpressure.
It does not accept another command until the preceding response is consumed.
There is no packet/framing interface.

While reset is high, command-ready, response-valid and backend handshake
outputs are suppressed. The resetting edge invalidates all lines, discards
dirty data and cancels the current command without a response. Payload and
memory-tag arrays are not cleared; validity prevents their stale use. **Flush
successfully before reset if dirty data must survive.** Reset must also cancel
or drain the backend transaction and any shared arbiter response. A delayed
pre-reset backend response cannot safely be attached to a post-reset request.
An already accepted backend write may survive reset; there is no rollback.

## Command and response ports

| Field | Meaning |
|---|---|
| `c_op=0` | Read the addressed word; strobe/data ignored |
| `c_op=1` | Merge selected bytes into the addressed word |
| `c_op=2` | Flush+invalidate the entire cache; address/data/strobe ignored |
| `c_op=3` | Invalid operation, status 1 without memory activity |
| `c_tag` / `r_tag` | Correlation tag, returned unchanged |
| `r_data` | Read word on successful read, otherwise zero |
| `r_hit` | Accepted non-no-op read/write found its line resident before work |
| `r_status` | 0 success, 1 invalid command, 2 writeback error, 3 refill error |

A zero-strobe **aligned** write succeeds without allocation, invalidation or
backend activity and reports `r_hit=0`. Alignment is checked first. Flush,
invalid commands, misses and failed misses also report `r_hit=0`.

Every nonzero-strobe write miss allocates the full line, even a full-word
write. A successful write response means the bytes are present in the cache;
they may still be dirty and absent from backing RAM. A successful flush
means all dirty writes were acknowledged and every cache line is invalid.
After flush, a new access refills from the backend. A read hit leaves a dirty
line dirty; clean line conflicts need no writeback.

## Backend port, errors and ownership

The backend has request valid/ready, write, address, 32-bit data and four byte
strobes, plus a held response valid/ready, 32-bit data and error. At most one
backend request is outstanding. Each writeback uses strobe `4'hf`; each
refill read uses strobe zero. Each accepted request needs exactly one
response. Write response data and error-response data are ignored. Backend
request fields are stable while stalled. The backend may present a response
immediately, but must hold it until the core raises response-ready. There is
no built-in timeout; lack of backend or consumer progress can stall forever.

Refill reads a complete line in increasing word order. Dirty writeback writes
the victim line in increasing word order, retaining its original address.
No new line is installed until all its refill reads succeed.

- **Writeback error (2):** stop immediately, preserve the complete old line
  valid and dirty, and do not perform the requested miss access. Earlier
  successful writes may already have reached RAM. Retrying a conflict or
  flush writes the whole dirty line again. A hit can still read its full data.
- **Refill error (3):** stop immediately and leave that slot invalid. An old
  victim already written successfully stays committed and invalidated. The
  requested read/write has not been applied; a retry refills from word zero.
- **Flush error (2):** slots are scanned from zero upward. Earlier slots have
  been written if dirty and invalidated; the failing dirty slot is retained;
  later slots are untouched. A later flush safely resumes by scanning again.

This is a cache for ordinary idempotent RAM. The caller owns all cached
addresses: external writes can make clean cached data stale, and external
reads can miss dirty updates. Coordinate a successful flush and quiescence
before handing memory ownership to another master. Disjoint memory accesses
are possible if their arbitration obeys the backend protocol. There is no
snoop protocol, bypass range, MMIO support, ECC or coherence mechanism.
An error does not imply that an already accepted physical memory write was
undone. Retrying failed writes must be safe for the chosen memory device.

## Architecture and latency

The cache has a direct-mapped payload array with one shared synchronous
read/write address, a registered read output, and separate tag/valid/dirty
metadata. Both hit writes and writeback use that registered read. No payload
array reset, multiword combinational read, line-wide mux, multiplier or vendor
primitive is required. Valid/dirty metadata is reset in parallel; memory tags
are only read when valid. No BRAM mapping or timing result is claimed.

Default logical arrays occupy 2,048 data bits plus 416 metadata bits;
maximum dimensions occupy 32,768 data bits plus 1,408 metadata bits, excluding
command/control/output registers. Resource risk is **LOW** by default and
**MEDIUM** at maximum due to indexed metadata, RAM mapping and control timing.

An unstalled hit presents its registered response three clock periods after
the accepting edge. Invalid commands and zero-strobe writes present it just
after the accepting edge. For a backend that accepts each offered request on
the next edge and has a response accepted on the following edge, a clean
miss presents its response after `2*LINE_WORDS+3` periods; a dirty miss after
`5*LINE_WORDS+3`. Every dirty line uses `LINE_WORDS` writes, and every refill
uses `LINE_WORDS` reads. Flush adds a scan per empty/clean slot and serialized
writeback for dirty slots. These are cycle-structure estimates, not measured
frequency or an unconditional completion deadline. Backend/consumer stalls
add delay; command interval also includes response acceptance and return to
idle.

## Offline files and connection example

From this directory:

```text
iverilog -g2012 -Wall -tnull -s word_writeback_cache -f files.f
iverilog -g2012 -Wall -tnull -s cache_scratchpad -f examples/files.f
```

`examples/cache_scratchpad.sv` connects the cache to the **unchanged** local
`../buffer_dma/rtl/mem_port_bram.v`. Its `RAM_DEPTH` is a power of two from
2 through 1,048,576. Initialize the backing RAM by the target flow before
reading it; the production example does not prefill memory. Complete every
line within backing capacity or expect a refill error. The example's cache
uses synchronous-high reset while the old BRAM control uses asynchronous-low
reset through `!rst`; RAM contents survive reset. `backend_reads`,
`backend_writes`, `backend_errors` count actual BRAM requests, not cache
commands, and reset with BRAM control. The dependency is included in
`examples/files.f` and hashed in the evidence; no network is needed.

## Bounded verification

From the repository root:

```text
python -B cores/storage/word_writeback_cache/check.py
```

The runner prefers the repository's OSS CAD Suite, caps **each** subprocess
at 20 seconds and removes its dedicated temporary directory. It records
tool invocations and SHA256 hashes of the current sources/dependency in
`verification.json`. It runs finite deterministic tests only.

| LINES / LINE_WORDS / TAG_W | Commands, including reset markers | Backend events | Final RAM words compared |
|---|---:|---:|---:|
| 1 / 1 / 1 | 321 | 300 | 256 |
| 2 / 2 / 4 | 353 | 561 | 256 |
| 16 / 4 / 8 | 464 | 1,433 | 320 |
| 4 / 8 / 16 | 380 | 2,268 | 256 |
| 64 / 16 / 32 | 800 | 10,941 | 3,200 |
| Total | **2,318** | **15,503** | **4,288** |

The independent Python oracle operates on whole resident blocks and
little-endian byte arrays, without modelling the RTL state machine. It
predicts the exact backend transaction trace and every visible response.
The TB independently maintains backing memory and checks read values,
write data/addresses/strobes, final RAM, one-outstanding behavior and stalled
request/response stability. Cases cover every byte mask, cold/hot/conflict
accesses, clean/dirty eviction, first/middle/last failures, partial flush,
retry preservation, the top address line, invalid operations/alignment,
zero-strobe writes and deterministic mixed traffic.

Each profile has six idle reset markers plus seven explicit in-flight
coordinated reset probes: lookup, stalled refill request, available refill
response, partial refill, dirty writeback request, available writeback
response and stalled cache response. The one-word profile substitutes a
waiting refill response for partial refill. Internal state is used only to
trigger these finite probes; there is no exhaustive-reset claim. Each probe
checks that a new read misses, matches surviving RAM, then hits.

The actual old-BRAM composition additionally checks byte merging, a dirty
conflict, flush and an out-of-range refill error. Eight illegal parameter
settings are rejected. The evidence has 23 recorded tool commands. The old
BRAM emits an inherited-timescale warning in example compilations; it is
unmodified. No wider regression or hardware validation is inferred.

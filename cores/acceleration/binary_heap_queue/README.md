# Online binary heap priority queue

Bounded dynamic minimum-priority queue with push, pop, non-destructive peek and
constant-time clear. Unlike frame Top-K or frame sorting, commands can interleave
in any order without a frame boundary; every successful push remains owned until
a pop, clear or reset. One outstanding command and one response at a time.

## Interface contract

`clk` is the sole rising-edge clock; `rst` is synchronous active high and cancels
the queue, in-flight operation and unconsumed response. Ready and valid are
suppressed whenever rst is asserted. Peers must also discard a canceled
transaction. There is no CE and no CDC: an edge with `s_valid && s_ready` accepts
a command, and an edge with `m_valid && m_ready` consumes a response. Sources
hold all command fields stable during a stall. Response fields and valid remain
stable until consumed. Another command is accepted only after the previous
response has been consumed, including rejected commands.

| Parameter | Default | Legal domain |
| --- | --- | --- |
| `KEY_W` | 16 | positive integer |
| `DATA_W` | 32 | positive integer |
| `CAPACITY` | 32 | 1 through 65535; resource feasibility is user's responsibility |
| `SIGNED_KEY` | 1 | 0 unsigned, 1 two's complement |

Keys are exact integers without fixed-point scaling. Payload is an opaque
unsigned bit field used as a secondary ascending key: minimum signed/unsigned
key first, then minimum unsigned payload. There is no insertion-order guarantee
for equal keys. Identical key/payload copies retain their multiplicity.
Parameters are static; there is no runtime reconfiguration or coefficient file.

| `s_op` / echoed `m_op` | Action | Successful `m_key,m_data` |
| --- | --- | --- |
| 0 | Push key/payload | Echo of inserted pair |
| 1 | Remove minimum | Removed pair |
| 2 | Read minimum, preserve queue | Minimum pair |
| 3 | Clear queue | Both zero |

`m_status=0` is OK, 1 is FULL on rejected push, and 2 is EMPTY on rejected
pop/peek. A full push echoes its rejected input pair and leaves the queue
unchanged; empty pop/peek return zero data and preserve emptiness. All four
operation codes are defined. `m_count` is post-command occupancy, valid with
the response; its width is `max(1,ceil(log2(CAPACITY+1)))`. Data and count during
an in-flight command are not an independent status interface. No frame, packet
or LAST signal applies: the command and response each form one transaction.

Output backpressure retains the response and blocks future commands. It cannot
interrupt a partially completed internal heap operation. Unbounded output stalls
mean there is no unconditional completion-time bound.

## Storage, latency and resource review

The heap uses 1-based addresses, one synchronous read port and one synchronous
write port, with no same-edge read/write collision. A read-request phase is
followed by a capture/compare phase. Memory contents are never reset; count and
control ownership prevent reading stale slots after clear/reset. There is no
external memory interface and no external address/error behavior. No vendor
primitive, external RAM, DSP or multiplication/division is required.

A held entry sifts through parent or child positions using a shared
lexicographic comparator; each visited heap level costs a bounded number of
cycles. This avoids parallel shifting of every queue entry. At the default,
storage is `32*(16+32)=1536` bits, plus held/read/child entries and small control.
The memory coding style permits RAM inference, but no specific BRAM/LUTRAM
mapping has been checked. Default qualitative risk is **LOW** for capacity and
**MEDIUM** for comparator/mux timing. Large parameter choices increase memory
linearly and comparison width directly; beyond local RAM capacity resource risk
is **HIGH**. These are structural judgments, not area or frequency measurements.

Without backpressure, command acceptance to response-valid latency is zero
cycles for clear/full/empty rejection, 2 cycles for peek or a one-entry pop,
at most `2*floor(log2(new_count))+1` cycles for push, and at most
`5*floor(log2(old_count-1))+5` cycles for pop with old_count greater than one.
The response handshake and return to the command boundary add two edges to
the interval between accepted commands. No II=1 throughput is claimed.

## Offline use and validation

`files.f` is the complete production source closure; the example exposes a
32-entry signed16-key/payload32 command interface. From this directory:

```sh
iverilog -g2012 -Wall -tnull -s binary_heap_queue -f files.f
python sim/run.py
```

The Python standard-library runner uses local OSS CAD Suite if available, or
PATH, with `IVERILOG`/`VVP` overrides. Every subprocess is limited to 15 seconds;
missing tools and failed/timed-out checks produce a non-pass report and exit.
All temporary vectors and simulator binaries are automatically removed.

Current status: **LINT_PASS** (Icarus syntax/elaboration), **UNIT_SIM_PASS**,
**HW_UNVERIFIED**. Evidence in `reports/validation.json` contains current source
hashes, actual commands and eight finite parameter configurations including the
default signed and unsigned modes, one-bit fields, capacity one and non-powers
of two. An independent Python minimum-of-multiset oracle checks ordering,
duplicate counts, capacity rejection, empty errors, clear/reuse, signed extrema
and payload ties. The BFM checks stalled responses and input gaps; each
configuration also cancels 26 transactions at different elapsed times during
push, pop or held response, then verifies clean reuse. This does not prove all
parameterizations or all possible command sequences. The example is an
**INTEGRATION_CANDIDATE**. Synthesis, PnR, STA and hardware were **NOT_RUN**.

`SOURCES.md` records semantic de-duplication and external candidate review.
All delivered code is original Apache-2.0 under the repository's LICENSE;
there are no third-party RTL, include files or initialization assets.

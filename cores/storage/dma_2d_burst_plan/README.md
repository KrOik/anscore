# 2D DMA byte-span burst planner

`dma_2d_burst_plan` owns one byte-oriented, strided 2D descriptor and emits its
complete row-major sequence of aligned burst plans. Before the first plan, it
checks that **every row** fits the address space. A bad later row therefore
produces one RANGE token and cannot expose a valid prefix. Signed, zero and
overlapping row strides are supported without changing row order.

Status: **LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED**. The fixed default wrapper
is **LINT_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. No synthesis, PnR,
STA, board work or expanded regression has been run. This is a standalone
address planner, not a payload mover or a complete AXI master. There are no
bus request, payload, response, completion-interrupt or coherency ports.

## Offline use

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s dma_2d_burst_plan -f files.f
iverilog -g2012 -Wall -tnull -s dma_plan32 -f example/files.f
python run_tests.py
```

The runner first tries `IVERILOG` / `VVP`, then the workspace OSS CAD Suite,
then PATH. Only Python's standard library and local Icarus are needed. Each
compiler or simulator child is independently limited to **20 seconds**. Vectors
and simulation executables live in a temporary directory. No source download,
network service, include, generated ROM, sibling RTL or vendor library is used.
`files.f` is the complete production closure; `example/files.f` adds a fixed
32-bit integration wrapper exposing every port. Run from the package root so
the manifest paths resolve. Standalone users can set the two tool environment
variables or put Icarus on PATH.

## Parameters and representation

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `ADDR_W` | 32 | 12..64 |
| `DATA_BYTES` | 4 | 1, 2, 4, 8, 16, 32, 64 |
| `MAX_BURST_BEATS` | 16 | 1..256 |
| `TAG_W` | 8 | 1..32 |

Illegal parameters deliberately instantiate the named undefined module
`dma_2d_burst_plan_invalid_parameter__see_README`, so elaboration fails.
`DATA_BYTES` is bytes per beat, not bits. All non-stride fields are unsigned.
`s_stride` is an `ADDR_W+1`-bit two's-complement value, allowing the complete
range `-2^ADDR_W .. 2^ADDR_W-1`. The caller must preserve its sign when wiring
a narrower source. Lengths are exact bytes; beat count is exact beats, not an
AXI LEN encoding.

## Descriptor input and ownership

| Port | Width | Meaning |
| --- | ---: | --- |
| `s_valid / s_ready` | 1 each | Descriptor accepted on a rising-edge handshake |
| `s_base` | `ADDR_W` | First byte of row zero |
| `s_row_bytes` | 32 | Byte count in every row, including partial beats |
| `s_rows` | 16 | Number of rows, at most 65,535 |
| `s_stride` | `ADDR_W+1`, signed | Difference between consecutive row starts |
| `s_tag` | `TAG_W` | Descriptor tag copied to every result token |

The intended byte address at `(row, column)` is the unbounded integer
`s_base + row*s_stride + column`, for `row < s_rows` and
`column < s_row_bytes`. Stride is measured from one **row start** to the next,
not from the previous row's end. Zero stride repeats the same byte span.
Negative stride walks backward between rows; bytes within each row always
advance. Overlapping bytes are planned again for each owning row. There is no
sorting, coalescing between rows, deduplication or padding in logical offsets.

Only one descriptor is owned at a time. `s_ready` is high only when idle and
reset is low. The source holds **all** input fields and `s_valid` stable while
`s_valid && !s_ready`, until handshake or reset. The core latches all fields at
acceptance; changes to a pending next descriptor cannot affect the owner.
There is no same-edge final-result/next-descriptor fallthrough.

If either dimension is zero, one canonical EMPTY token is generated and all
range inputs are ignored. For nonempty descriptors, any intended byte below
zero or above `2^ADDR_W-1` produces one canonical RANGE token. No masking,
truncation or saturation makes an invalid descriptor valid. A one-row
descriptor ignores stride mathematically, including its extreme values.

## Result stream

| Port | Width | Meaning for an OK plan (`m_keep=1`) |
| --- | ---: | --- |
| `m_valid / m_ready` | 1 each | Token transfers on rising-edge handshake |
| `m_status` | 2 | 0 OK, 1 EMPTY, 2 RANGE; 3 never emitted |
| `m_tag` | `TAG_W` | Accepted descriptor tag |
| `m_keep` | 1 | One for a burst plan; zero for a status-only token |
| `m_addr` | `ADDR_W` | Beat-aligned address of the first beat |
| `m_beats` | 9 | Positive burst beat count, at most 256 |
| `m_bytes` | 15 | Number of intended row bytes covered by this plan |
| `m_first_mask / m_last_mask` | `DATA_BYTES` each | Intended byte lanes in first/last beat |
| `m_row` | 16 | Zero-based row index |
| `m_row_offset` | 32 | Intended bytes preceding this plan within the row |
| `m_offset` | 48 | Intended bytes preceding this plan in row-major order |
| `m_row_first / m_row_last` | 1 each | First/last plan in this row |
| `m_first / m_last` | 1 each | First/last token of the descriptor |

Lane zero is the lowest addressed byte. Middle beats have all lanes enabled.
For a one-beat plan, both masks are identical and describe their intersection.
`m_bytes` equals the sum of enabled bytes across the burst, not
`m_beats*DATA_BYTES` when an edge is partial. Each burst covers the largest
possible prefix of the remaining row subject to the configured maximum beats
and this invariant:

```text
m_addr % DATA_BYTES == 0
1 <= m_beats <= MAX_BURST_BEATS
(m_addr % 4096) + m_beats*DATA_BYTES <= 4096
```

The 4 KiB rule can impose a smaller effective maximum. For example, 64-byte
beats permit at most 64 beats per burst even when the parameter is 256. The
aligned first/last beats may include lanes outside the intended span; only
masked-in bytes belong to this descriptor. A downstream write engine must
apply these masks; a downstream read engine must trim unwanted lanes. A
consumer may derive an 8-bit AXI LEN as `m_beats-1` only for `m_keep=1`.
The planner does not observe whether a downstream operation succeeds.

EMPTY and RANGE tokens have `m_keep=0`, the accepted tag and status,
`m_first=m_last=1`, `m_row_first=m_row_last=0`. All numeric fields and both
masks are zero. Such a token describes no bus work. There is no additional
completion token after a successful descriptor: its final plan has `m_last=1`.
Here `m_last` means that planning is complete when transferred, not that
payload transfers have completed. Fields are meaningful only when valid.

The consumer can stall arbitrarily: `m_valid` and **every** output field remain
stable until transfer or reset. While a held token is stalled, all core
registers retain their values. Logical offsets count intended bytes, so an
overlap or repeated row still advances `m_offset`. The 48-bit field holds every
possible logical offset because `65535*(2^32-1) < 2^48`.

For default parameters, base 4093, row bytes 9, rows 2, stride -5 produces:

| Row | Address | Beats | Bytes | First mask | Last mask | Row offset | Logical offset |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 4092 | 1 | 3 | `1110` | `1110` | 0 | 0 |
| 0 | 4096 | 2 | 6 | `1111` | `0011` | 3 | 3 |
| 1 | 4088 | 2 | 8 | `1111` | `1111` | 0 | 9 |
| 1 | 4096 | 1 | 1 | `0001` | `0001` | 8 | 17 |

The plan at 4088 stops at byte 4095 because of the page boundary, then the
final byte is planned at 4096. Logical offsets exclude all masked-out lanes.

## Reset, clocking and timing

`rst` is active high and synchronous; hold it across a rising edge to cancel
the owned descriptor, held result and all preflight work. `s_ready` and
`m_valid` are combinationally forced low whenever `rst=1`. All registers clear
at the reset edge; when reset is released the core is immediately idle and
accepts a fresh descriptor. Reset can discard an unaccepted plan. A consumer
must share this cancellation boundary; already accepted downstream payload
work is outside this planner's ownership. There is one clock, no clock-enable
port and no CDC. Ordinary stalls do not gate the clock or cancel ownership.

Measure latency from the descriptor-accepting edge to the first visible valid
token after an edge:

| Descriptor | First valid delay |
| --- | ---: |
| EMPTY | 0 clock periods (same accepting edge) |
| Nonempty RANGE | 17 clock periods |
| Nonempty OK | 18 clock periods |

Every nonempty descriptor uses 16 shift/add cycles, even for one row or zero
stride, followed by the range-check cycle. OK uses one further planning cycle.
After each nonfinal output transfer, the next plan becomes valid **one** clock
period later. With an always-ready consumer, adjacent transfers are two clock
periods apart. A final output handshake returns to idle immediately after that
edge; a new input can transfer at the following edge. Backpressure extends the
total descriptor duration without changing the first-valid computation delay.

## Architecture and structural resource budget

The last-row displacement is `(rows-1)*abs(stride)`. A 16-step shift/add unit
computes it with one magnitude accumulator; there is no parallel multiplier
or DSP requirement. Because stride is constant, first and last row starts are
the extrema of all row starts. The core checks the minimum start and maximum
start plus `row_bytes-1` using signed widened arithmetic **before** emitting
anything. Workspace width is `max(ADDR_W+18,34)`: 50 bits by default, 82 at
maximum parameters. The 34-bit floor also preserves unsigned 32-bit lengths
when the address width is small.

Once validated, scalar row/cursor counters advance only as plans transfer.
Planning uses constant power-of-two division/remainder, boundary/count minima
and a fixed lane-mask decoder. Address updates avoid creating a wrapped
exclusive-end address after the final byte. Each new row starts from its
retained row base plus signed stride; it never inherits the last row's cursor.

| Declared state | Default bits | Maximum bits |
| --- | ---: | ---: |
| Internal scalar registers, including preflight | 429 | 621 |
| Held output fields | 175 | 351 |
| Payload/descriptor memory arrays | 0 | 0 |

These are manually counted declarations, not synthesis cell or flip-flop
measurements; duplicate registers or unused widths may optimize away. The
combinational integer temporaries are not state. Qualitative risk is **LOW**
at default and **MEDIUM** at maximum: widened preflight add/compare chains,
mask fanout and the plan arithmetic are potential timing paths. No Fmax,
LUT/DSP/BRAM count, power number or physical timing closure is claimed.

## Finite verification and evidence boundaries

`verification.json` records 23 local tool invocations, including ten named
invalid-parameter elaboration rejections; every positive child has empty
stderr. Five profiles cover address/data-bytes/max-beats/tag settings:
`12/1/1/1`, `16/4/3/3`, `32/4/16/8`, `48/8/64/16`, `64/64/256/32`.

The independent Python oracle enumerates every row start with unbounded
integers for range validation. For accepted finite cases it enumerates each
intended byte, constructs occupied beat masks, then groups adjacent occupied
beats by count and page. It does not reproduce the RTL head/capacity formula
or endpoint-only range proof. Packed expected tokens check all fields and the
complete order, including duplicates in repeated/overlapping rows. Testbench
geometry checks independently enforce alignment, beat limits, page bounds
and one-beat mask equality. Timing and exact held-result/source stability are
checked at clock boundaries.

The checked run contains **2,971 descriptors / 77,796 tokens**, 1,548 local
exhaustive lane/length/row/stride products, 404,716 enumerated bytes,
1,385,416 row-range checks, 304 page splits, and a fully completed 65,535-row
descriptor in the default profile. Every result is deliberately held for
three rising edges; observed counters include 233,388 held-output cycles and
437,926 real source-stall cycles. Errors include late underflow/overflow,
wide displacement products, extreme signed strides and large row lengths.

There are **70 immediate phase resets and 70 fresh one-byte recoveries**:
idle; shift/add iterations 0/7/15; range check; planning; held EMPTY/RANGE;
held first, middle, row-final and descriptor-final plans; and huge-row
preflight/prefix probes. Each probe invokes `reset_now` at the observed target
without an intervening rising edge. Every recovery completes and checks a
new one-byte descriptor, then observes idle cycles for stale output. For
`row_bytes=2^32-1`, only the first plan is checked then canceled on legal wide
address profiles; narrow profiles check the canonical rejection. The huge
accepted descriptor is **not** claimed as a fully enumerated transfer. Tests
are finite and deterministic, not formal proof or an exhaustive legal-space
claim. All ten local non-report files are strict UTF-8/LF and hashed in the
report; dependencies are empty. See `SOURCES.md` for read-only deduplication
and the fixed-commit external source/full-license preflight.

All local material is original Apache-2.0 work; `LICENSE` permits this package
to be used independently. No sibling or upstream source is redistributed.

# RAM scatter/gather range map

`ram_sg_range_map` stores an ordered scatter/gather table and translates a
logical byte interval into the corresponding physical spans. LOAD atomically
replaces the table; QUERY reuses it without reloading. Physical segments may
overlap, repeat, run in any address order or be adjacent. Original segment
boundaries and indices are preserved rather than coalesced. No payload bytes
or external memory transactions are transferred by this module.

Evidence states are recorded in `verification.json`: `LINT_PASS` and
`UNIT_SIM_PASS` apply only if that receipt records the complete frozen finite
matrix as passed. Hardware remains `HW_UNVERIFIED`; synthesis, PnR, STA, board
tests and expanded regression are not run. The source and license preflight
is documented in [SOURCES.md](SOURCES.md).

## Parameters and dependencies

| Parameter | Default | Supported unsigned width/count |
| --- | ---: | --- |
| `MAX_SEGS` | 16 | 1..32 table slots |
| `ADDR_W` | 32 | 1..64 physical address bits |
| `LEN_W` | 16 | 1..32 segment length bits |
| `TAG_W` | 8 | 1..32 opaque command tag bits |

Let `N=MAX_SEGS`, `A=ADDR_W`, `L=LEN_W`, `T=TAG_W`,
`IW=max(1,ceil(log2 N))`, `CW=ceil(log2(N+1))`, and
`TW=L+ceil(log2 N)`. For N=1 the last logarithm is zero. Unsupported
parameters deliberately instantiate a named missing module and must fail
elaboration. All arithmetic and interface values are unsigned integers;
there is no fixed-point format, clock enable or CDC.

`files.f` contains the one production RTL source. `example/files.f` also
contains the complete default-width `sg_map16` wrapper. There are no vendor
primitives, packages, includes, initialization images or network dependencies.
The optional test runner uses Python's standard library plus local Icarus
Verilog/`vvp`; vectors and expected results are generated offline.

## Handshakes and ownership

All transfers occur on a rising `clk` edge with `valid && ready`. A source
must keep valid and every associated field stable while valid is high and
ready is low. There is one command owner: LOAD entry reception, publication,
QUERY scanning and all held output tokens block subsequent commands.
`c_ready` is high only in idle; `e_ready` is high only while the current LOAD
owns the entry stream. Entries may be preoffered before their LOAD command
but are accepted only after that command. Command and entry channels hold
independently. An output holds every field until its transfer.

`rst` is active high and synchronous for state and metadata. While asserted,
`c_ready`, `e_ready` and `m_valid` are immediately gated low. At the next
rising edge reset cancels the current transaction, discards any pending
output and clears the active table. All source obligations for canceled
tokens end at reset. RAM payloads and its read register are unreset; zero
active count/total hides them, so no stale entry or output becomes visible.
CLEAR also hides all entries through metadata and requires no RAM sweep.

## Commands and LOAD entries

`c_op[1:0]`, `c_offset[63:0]`, `c_bytes[63:0]` and `c_tag[T-1:0]`
belong to each accepted command. Tag and opcode are returned unchanged.

| Opcode | Operation | Result |
| ---: | --- | --- |
| 0 | LOAD | Consume entry tokens through the accepted `e_last=1`, then one ACK |
| 1 | QUERY | Ordered physical fragments, or one EMPTY/RANGE ACK |
| 2 | CLEAR | Clear active count/total, then one OK ACK |
| 3 | Reserved | One BAD_OP ACK; table retained |

LOAD and CLEAR ignore `c_offset/c_bytes`. Each LOAD entry has
`e_base[A-1:0]`, `e_bytes[L-1:0]`, `e_keep`, `e_first` and `e_last`.
The first accepted entry token must assert FIRST; every later token must
deassert it, including masked tokens. LAST terminates the input stream and
may be asserted on its first token. There is no per-entry tag.

Only `e_keep=1` tokens occupy slots. Kept zero-byte segments are legal,
retain their exact base and original slot index, and contribute no logical
bytes. A masked entry's base/length are ignored, but FIRST/LAST still apply.
An empty replacement is one correctly framed masked LAST token. All kept
entries, including zero-byte entries, count toward N. The inclusive physical
last address `base+bytes-1` must fit A bits when bytes is nonzero.

LOAD writes only the inactive RAM bank, with count saturated at N. Errors
accumulate without an early ACK: the entire stream drains through LAST,
including excess tokens and their range/framing checks. The error bits are:

| `m_load_errors` bit | Sticky condition |
| ---: | --- |
| 0 | Any kept nonzero span exceeds the physical address range |
| 1 | FIRST differs from the required first/later-token framing |
| 2 | Any kept token exceeds the N-slot capacity |

After LAST, an error-free candidate replaces the entire active table in one
publication edge, including an empty candidate. Any error returns
LOAD_REJECT and leaves the previous active table, count and total exactly
intact. No QUERY can observe a partially loaded candidate, and another
command cannot be accepted until the LOAD ACK transfers.

## QUERY and output fields

The logical map concatenates all segment byte intervals in entry order.
For a nonzero request, the module computes the full 65-bit unsigned sum of
the 64-bit offset and byte count before comparing it to the active total;
there is no prevalidation narrowing or wraparound acceptance. A request
beyond the map, including an overflowing unsigned64 sum, produces RANGE.
`c_bytes=0` always produces EMPTY and ignores the offset, even on an empty
table. A nonzero query of an empty map produces RANGE.

Each successful QUERY fragment describes the intersection with one original
nonzero segment. `m_addr[A-1:0]` is the physical starting address,
`m_bytes[L-1:0]` its nonzero byte count, `m_offset[TW-1:0]` the absolute
logical starting offset, and `m_segment[IW-1:0]` the original slot index.
Fragments are returned in logical order. FIRST marks only the first
fragment; LAST marks the fragment exhausting the requested byte count.
No separate QUERY completion ACK follows LAST. Validated queries never
start a partial success stream followed by an error token.

Every output includes `m_op`, `m_tag`, `m_status[2:0]` and
`m_load_errors[2:0]`. Status codes are OK=0, EMPTY=1, RANGE=2,
BAD_OP=3 and LOAD_REJECT=4. Fragments have `m_keep=1`, status OK and zero
error bits. ACKs have `m_keep=0`, FIRST=LAST=1, and zero address, byte count,
logical offset and segment index. Error bits are meaningful only for LOAD
and zero for other opcodes. In both forms `m_total[TW-1:0]` and
`m_segments[CW-1:0]` describe the current active map, including the retained
old map after a rejected LOAD. These fields also remain stable under
backpressure because ownership blocks map updates.

## Exact timing

Latency below counts complete clock periods from the accepting edge to
the first edge after which `m_valid` is high, independent of `m_ready`.

| Operation | First-valid latency |
| --- | --- |
| Valid nonempty QUERY, first matching original segment i | `2*(i+1)`, at most `2*N` |
| LOAD | 1 period after the accepted LAST entry |
| EMPTY/RANGE QUERY, CLEAR, BAD_OP | 0 periods after the command edge |

QUERY uses a synchronous RAM READ edge and a CHECK edge for every inspected
segment, including zero segments and segments before the requested offset.
After a fragment at index i transfers, the next fragment at index j becomes
valid after `2*(j-i)` periods. With an always-ready sink their transfer gap
is `2*(j-i)+1` periods. Zero segments therefore increase the gap; adjacent
nonzero segments have a two-period next-valid latency. Held output periods
add directly to completion time. The final output transfer returns to idle;
a new command is accepted no earlier than the next rising edge.

## Structure and declared budgets

One packed array contains two banks of N `(base,length)` rows:
`2*N*(A+L)` declared RAM bits, 1536 at defaults and 6144 at maximum widths.
Loads write the inactive bank. Queries read the active bank synchronously
into one packed read register. Reads and writes never overlap, and RAM is
not reset. A sequential scan shares the address arithmetic and interval
comparison instead of expanding N parallel comparators.

Clocked scalar declarations, including the RAM read register and output
registers, are `14+2*CW+5*TW+IW+2*A+2*L+T` bits: 232 default and 440
maximum. This is a logical declaration budget, not a LUT, FF or BRAM
measurement. There are no multipliers or external memory peers. Resource
risk is LOW at the supported small table sizes; implementation timing and
RAM inference are UNKNOWN until target-specific synthesis. No Fmax, power,
device fit or board throughput is claimed.

## Frozen finite checks

`TEST_PLAN.json` is frozen before the first HDL child. Its five profiles
cover N=1, non-power-of-two N, LEN wider than ADDR, defaults and maximum
widths. The 19 children are one core/example compile, five compile/simulate
pairs and eight invalid-static rejections. Every compiler/simulator child
has a fixed 20-second timeout. A timeout is terminal; a successful matrix
cannot be rerun. Ordinary failures preserve source, plan, receipt and
artifacts before correction within the same matrix.

The independent Python oracle intersects the requested absolute interval
with prefix intervals of an immutable segment list; small maps also expand
every byte for a second check. It compares every output field, every active
RAM row, exact first-valid latency and subsequent fragment availability
gaps. Actual queued commands and future
LOAD entries are independently held until acceptance; ACKs and fragments
are held under backpressure. Each profile adds sixteen immediate reset
boundaries across all seven states, each followed by a complete four-command
LOAD/query/rejected-LOAD/query recovery. Counts and hashes are in the
receipt. The checked command is `python -B run_tests.py` from this directory
after freezing once with `python -B run_tests.py --freeze`; the runner's
checked local tool path is `tools/oss-cad-suite/oss-cad-suite` at repository
root. Nothing fetches dependencies or contacts a network.

# Frame-private byte write coalescer

`ram_byte_write_coalescer` combines a complete bounded frame of arbitrary byte
stores into one acknowledged, byte-enabled write per distinct aligned bus word.
The final accepted value of each byte wins. For four-byte words, writes
`(0x101,0xaa),(0x100,0x12),(0x101,0x34)` produce address `0x100`, data
`0x00003412`, strobe `0011`. Unselected output bytes are always zero.

The current `verification.json` is authoritative: LINT_PASS and UNIT_SIM_PASS
require its entire original frozen matrix to pass. Physical maturity remains
HW_UNVERIFIED. No synthesis, PnR, STA, board or expanded/inherited regression
is run. Fixed-source/license preflight and actual semantic deduplication are
recorded in [SOURCES.md](SOURCES.md). All local implementation is original
Apache-2.0 work under the included [LICENSE](LICENSE).

## Parameters and address domain

| Parameter | Default | Legal |
| --- | ---: | --- |
| MAX_BEATS (N) | 16 | 1..32, including nonpowers of two |
| ADDR_W (A) | 32 | 1..64 |
| DATA_BYTES (B) | 4 | 1, 2, 4, 8; log2(B)<=A |
| TAG_W (T) | 8 | 1..32 |

Input `s_addr[63:0]` is always a complete unsigned **byte** address. Each kept
address must be less than `2**A`; high host bits are checked before capture
narrows it to A bits. No wraparound, alias or silent truncation is accepted.
All 64-bit addresses are legal when A=64. `s_data[7:0]` is an opaque byte.

Output `q_addr[A-1:0]` clears the low log2(B) input address bits. Byte lane j
uses `q_data[8*j+:8]` and `q_strb[j]`. This is a lane convention, without endian
conversion. B is a power of two and B<=2**A, so each aligned output word fits
the domain, including the word containing its final address. A=log2(B) is
legal and has exactly one representable word base, even when N is larger.

The internal index width is I=max(1,clog2(N)); count width C=clog2(N+1).
Unsupported static settings fail elaboration through the named missing module
`ram_byte_write_coalescer_invalid_parameters__see_README`.

## Input ownership, framing and errors

All ports share rising-edge `clk`, synchronous active-high `rst` and ordinary
ready/valid. There is no CE or CDC. Every source retains valid and all fields
through its handshake or reset. Legacy CE-qualified interfaces need an adapter.

`s_valid && s_ready` accepts one token with address, data, KEEP, FIRST, LAST
and tag. The **first accepted token**, including a masked one, owns the tag.
Its FIRST must be one; every later token's FIRST must be zero. FIRST and LAST
on a single token are legal. LAST on any accepted token closes that frame,
including a masked tail. A missing LAST retains ownership indefinitely until
reset; there is no inferred tail or timeout. A later accepted token after LAST
belongs to a later frame and must have FIRST=1. Later tags are ignored.

KEEP=0 ignores address/data and consumes no capacity, while FIRST/LAST still
participate in framing. Arbitrary masked tokens can appear anywhere. Capacity
counts **distinct aligned valid-address bases**, rather than bytes or accepted
tokens. Existing bases can be updated while the table is full; there is no
bound on repeated writes before LAST. New bytes at existing bases set their
strobes. Repeated exact-byte writes replace only that byte with the latest value.

FORMAT and RANGE errors accumulate independently across every accepted token.
FORMAT means the first FIRST is missing or a later FIRST is set, including
masked tokens. RANGE means any kept full64 address is outside the configured
domain. These two errors do not stop private combining of other valid addresses.
An out-of-range address is never stored or compared after narrowing.

The first absent valid base when N bases are retained sets CAPACITY. That
token is not stored; all later table scanning/writing stops while the remaining
frame drains through LAST. FIRST and full64 range checks continue during this
drain, so their flags can combine with CAPACITY. Distinct valid bases alone
determine capacity even if an earlier token already set FORMAT or RANGE.

No external request occurs before the complete frame closes and validates.
A frame with any FORMAT/RANGE/CAPACITY flag issues **zero** external writes;
its private RAM is discarded through ownership metadata. There is no partial
publication, eviction, sorting or coalescing across frames.

## Acknowledged writes and one result

`q_valid/q_ready/q_addr/q_data/q_strb` offers a write; all fields stay stable
while held. Distinct bases are issued once each in their first input occurrence
order. Every request has a nonzero strobe, and inactive data lanes are zero.
There is no external read signal or read allocation. At most one write is
outstanding. `p_valid && p_ready` accepts exactly one boolean `p_error` ACK
for each accepted write; there is no response-data field.

The peer may offer the real ACK on the request-accepting edge, but must retain
it: p_ready becomes active only in the following WAIT_ACK phase. No unsolicited,
duplicate or stale ACK is allowed. Request stalls and missing ACKs may last
indefinitely. An ACK error does not stop subsequent distinct writes, trigger
retry or restore earlier memory contents. A failed ACK does not establish
that the physical write had no effect.

`m_valid && m_ready` retires exactly one complete-frame result, with no output
KEEP/FIRST/LAST or additional interrupt. Every field stays stable while held:

| Field | Meaning |
| --- | --- |
| m_tag[T-1:0] | First accepted token's tag |
| m_status[4:0] | Bits below; no other values/meaning |
| m_beats[C-1:0] | Number of issued and acknowledged writes, including failed ACKs |
| m_error_mask[N-1:0] | Bit i is the error ACK for write i in first-base-occurrence order |

Status bit0 is EMPTY, bit1 FORMAT, bit2 RANGE, bit3 CAPACITY and bit4
WRITE_ERROR. Any input-error frame returns only its ORed bits1..3, with
beats=mask=0. A well-framed all-masked frame returns only EMPTY, beats=mask=0.
A valid nonempty frame returns zero or only WRITE_ERROR; beats is its distinct
base count, bit4 is exactly the OR of its error mask, and mask bits >=beats
are zero. There are no invented successful writes after a failed ACK.

One frame owns loading, merging, every external request/ACK and every held
result. A real next frame may be preoffered while blocked. Its first token can
transfer on the edge **after** the previous result retires; there is no same-edge
fallthrough. Output backpressure therefore also prevents reuse of its table.

This service is for ordinary idempotent RAM where the caller authorizes
eliminating overwritten stores and reordering stores across aligned words.
Other masters/observers must coordinate that ownership. This is not an MMIO
ordering service, coherent cache, atomic multiword transaction or rollback
mechanism. It does not promise visibility of intermediate byte stores.

## Reset, RAM schedule and exact clocks

Reset immediately gates s_ready, q_valid, p_ready and m_valid low. Hold it
across a rising edge. The edge cancels the frame and held result, clearing
scalar ownership and errors; RAM and its read register are not reset or swept.
A new frame overwrites each whole row before its count permits any read.
There is no stale-result publication or data-erasure promise.

Reset is a **shared cancellation boundary with the ACK peer**: cancel both
unaccepted requests and accepted-but-unacknowledged writes in its bookkeeping,
and discard their old ACKs. An untagged old ACK during a new frame cannot be
distinguished. Already accepted physical write effects may survive reset;
callers replay only where those semantics are allowed.

One packed synchronous RAM row stores `{aligned_base,data,strobe}`. Its
registered read is used first by a serial address scan and later by external
write replay. APPEND and MERGE writes occupy separate states from SCAN_READ
and OUT_READ. No read-during-write collision mode is consumed. A single base
comparison and selected-byte update replace a CAM/parallel comparator bank.
There is no multiplier, divider, DSP requirement or vendor primitive.

Logical RAM is `N*(A+9*B)` bits: **1088 default / 4352 maximum**. Declared
clocked scalar storage, including the unreset row register, is exactly
`2*A+9*B+2*I+C+T+N+16`: **153 default / 296 maximum**. The constant16 comprises
state4, byte8, pending-tail1 and sticky frame errors3. Count, two indices, tag,
pending address, ACK bitmap and the packed read register are included.
Combinational comparison, mux and decode logic are additional. Qualitative
implementation risk is LOW default / MEDIUM maximum. These are source-level
bits, not measured LUT/FF/BRAM/DSP, memory mapping, Fmax or power evidence.

A kept valid byte scans K existing rows: K is one plus its matching row's
first-appearance rank, or the current distinct count for a new base. Its update
commits `2*K+1` periods after acceptance; the first append needs one period.
A full-table miss sets CAPACITY after `2*N` periods. Masked, out-of-range and
capacity-drain tokens need zero work. Earliest next input acceptance after a
successful kept byte is `2*K+2`, at most **34 default / 66 max** periods.

Let h be the last token's work, U the valid frame's distinct count, and W the
observed q_valid/not-ready plus p_ready/not-valid edges. From LAST acceptance
to first result-valid, the exact latency is `h+3*U+1+W` for valid nonempty
frames, and `h+1` for invalid/empty frames. Successful internal latency is at
most `5*N+2`: **82 default / 162 max**, plus W. Invalid frames are bounded by
`2*N+2`; an empty frame takes one period. Earliest result transfer is the next
edge after valid. Input gaps, backend waits and result holds prevent an
unconditional completion deadline; these are RTL schedules, not hardware rates.

## Offline closure and frozen finite evidence

`files.f` closes production RTL. `example/files.f` adds `byte_scatter16`, a
fixed default wrapper exposing every port. No sibling HDL, generated ROM,
network download, include or vendor library is required. From this directory:

```text
python -B run_tests.py --seal
python -B run_tests.py
```

The seal is made once before the first HDL child and binds every local source,
document, file list, generator and fixture. The runner records one original
attempt, rejects any rerun and verifies every source before/after execution.
It uses only Python's standard library and local Icarus, with IVERILOG/VVP
path overrides and the repository OSS CAD Suite fallback.

[TEST_PLAN.json](TEST_PLAN.json) was frozen before any RTL: six N/A/B/T profiles
`1/1/1/1,3/1/2/3,3/5/2/3,7/16/4/8,16/32/4/8,32/64/8/32`, 24 exact children
(two lints, six compile/simulation pairs, ten named parameter rejections).
Every compiler/simulator has a hard 20-second limit. Timeout is terminal,
without retry, reduced stimulus or added time. An ordinary failure archives
exact sources/plan/seal/receipt, remaining NOT_RUN entries and artifacts, then
stops for specific root repair authorization.

The 960 main frames contain 41,195 input tokens and 1,446 expected external
writes. Every single host address bit is isolated in its own frame. Directed
and fixed seeded cases cover every lane, endpoints, replacement, interleaved
revisits, full existing-base updates, overflow, all error combinations, masked
framing, empty frames and first/middle/last/all failed ACKs.

The independent oracle is a byte-address dictionary and insertion-ordered base
keys. A separate first-occurrence rank certificate supplies scan counts and
exact work/latency. All complete inputs, peer waits/errors, output expectations
and per-token row effects are frozen JSON/TXT, never generated during HDL.
The TB checks every request, ACK, result, actual synchronous RAM read/write,
every owned row and all exact clocks. Actual q/ACK/result/phase records remain
in raw child stdout. Real next tokens, four-cycle held results, request stalls,
early-offered and delayed ACKs exercise ownership and stable fields.

There are **132 immediate phase cancellations**, followed by 132 complete fresh
frames with **1505 expected fresh writes**, then five idle clocks apiece.
Target IDs observe actual state/index before reset without another active
edge. The missing-LAST load target pauses four clocks after a masked prefix.
N=1 aliases coincident first/middle/last indices. N3/A1/B2 can represent only
one base and cannot overflow; A64 cannot produce RANGE. These exclusions and
aliases are explicit before tools. Fresh frames fill each profile's entire
reachable capacity, including all byte lanes. The evidence is finite, without
formal proof, whole-space exhaustiveness or board integration claims.

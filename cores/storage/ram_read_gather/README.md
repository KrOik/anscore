# Exact duplicate-suppressing read gather

`ram_read_gather` loads a bounded frame of raw read addresses, reads each
distinct address once through an acknowledged external port, and returns one
data/error token per kept address in the original order. Duplicate addresses
reuse their first read's data and error. There is no cache lifetime beyond the
frame. Consecutive frames read the same address again. Semantic deduplication
and fixed full-source/license preflight are recorded in [SOURCES.md](SOURCES.md).

## Ownership and input framing

All ports use one rising-edge clock, synchronous high-active `rst` and ordinary
ready/valid. There is no CE or CDC. Every source retains valid and all its
fields until handshake or reset. Only one frame owns input loading, every
external read, RAM processing and every held output. A new frame can transfer
on the edge after the final output retires; there is no same-edge fallthrough.

Input fields are `s_addr[ADDR_W-1:0]`, `s_tag[TAG_W-1:0]` and KEEP/FIRST/LAST.
Every accepted token contributes framing, even when KEEP=0. The first accepted
token owns the tag and must have FIRST=1; every later accepted token must have
FIRST=0. LAST closes the frame. No LAST means indefinite loading until reset.
Kept addresses receive compact indices 0..n-1; masked tokens have no address
meaning and consume no slot. Arbitrary masked tokens may precede, separate or
follow kept addresses. Capacity is counted in kept items, including duplicates.
The retained count saturates at MAX_ITEMS and further kept tokens set overflow.
FIRST and overflow errors are sticky; the whole frame drains through LAST,
then returns one canonical status token. No external request occurs before
LAST or for any malformed/empty frame.

Addresses are exact unsigned external read identifiers, without byte/word
alignment, narrowing, lane selection or arithmetic. A downstream adapter
defines their physical units. The caller provides a domain where repeating
the same address may share one observation: duplicates intentionally do not
repeat reads or side effects. Distinct addresses are requested in first-input
occurrence order. Their observations are sequential and do not form an atomic
memory snapshot. This interface has no writes, bursts, coherency or cache
invalidation operation.

## External request and response

`q_valid/q_ready/q_addr` transfers a read request. `p_valid/p_ready/p_data/p_error`
transfers exactly one response for each accepted request, in order. There is
at most one outstanding request. Request address remains stable through
backpressure. The core asserts response-ready only while awaiting that request.
A peer may offer its response on the request-accepting edge, but must retain
it: the core cannot transfer it until the next edge. There are no request IDs
or epochs. The peer must not produce unsolicited or duplicate responses.

Read errors do not stop processing other addresses. A response with p_error=1
stores data=0 regardless of p_data; all duplicates reproduce that error and
zero data without retry. A successful response stores the full DATA_W-bit
pattern. A frame's external request count is exactly its number of distinct
addresses, including addresses whose responses fail.

Reset is the **shared cancellation boundary of this core and the response
peer**. Assert it across an edge and cancel both unaccepted requests and all
accepted-but-unanswered reads in the peer. The peer discards those responses
and must not deliver them after reset. An old untagged response arriving during
a new frame cannot be distinguished from the new response; allowing that
behavior violates this interface. No silent post-reset response drain is used.
Already accepted read side effects cannot be undone by this core.

## Ordered output and status

`m_valid/m_ready` transfers output. All fields are stable while held.

| Field | Successful nonempty frame |
| --- | --- |
| m_status[2:0] | 0 |
| m_keep | 1 |
| m_error / m_data | Recorded read error and zero-on-error DATA_W-bit data |
| m_addr | Original kept address |
| m_tag | First accepted input token's tag |
| m_index | Compact original kept index, 0..n-1 |
| m_count | Total kept items n |
| m_unique | Total distinct physical read requests |
| m_first / m_last | First/final output token |

An empty well-framed input emits status=1. FIRST errors emit 2, overflow emits
4, and both emit 6. Values 3/5/7 are never emitted. These status-only tokens
have keep=0, error/data/address/index/count/unique=0, first=last=1 and the first
input tag. Framing errors take precedence over empty. A read error is a kept
token with status=0 and m_error=1, independent of frame-format status.

Reset immediately gates s_ready, q_valid, p_ready and m_valid low. Its edge
cancels loading, processing and held output, resets scalar ownership and
returns IDLE without a RAM-clearing sweep. RAM and its read register are not
reset or erased. Loading writes every retained row before use; item i compares
only earlier fully computed rows. Replay begins after all current-frame rows
are complete. Stale RAM cannot become a result and no data-erasure guarantee
is made. The caller replays canceled work after the peer shares cancellation.

## Parameters, architecture and budget

| Parameter | Default | Legal range |
| --- | ---: | --- |
| MAX_ITEMS | 16 | 1..32, including nonpowers of two |
| ADDR_W | 32 | 1..64 |
| DATA_W | 32 | 1..64 |
| TAG_W | 8 | 1..32 |

Local index width IW=max(1,clog2(MAX_ITEMS)); count width
CW=clog2(MAX_ITEMS+1) represents 0..MAX_ITEMS exactly. Illegal static settings
fail elaboration through `ram_read_gather_invalid_parameters__see_README`.

One packed synchronous RAM contains `{address,error,data}` for each retained
item. Its single registered read port alternates current-item loading,
earlier-address scanning and output replay. Loading and result STORE use one
write port in phases mutually exclusive with reads. No read/write collision
semantics are required. On a match, the already computed row supplies data and
error; on a miss, one external read supplies them. STORE commits the result
before the next item. There is no separate unique table, mapping RAM, CAM,
parallel comparator bank, payload reset, multiplier, divider or vendor primitive.

Logical RAM is `MAX_ITEMS*(ADDR_W+DATA_W+1)` bits: **1040 default / 4128 max**.
Scalar storage, including the unreset RAM-read/output register, is exactly
`2*ADDR_W+2*DATA_W+3*IW+2*CW+TAG_W+8` bits: **166 default / 323 max**.
The eight constant bits are state4, sticky frame errors2 and two error bits
(one in result storage, one in the RAM read register); the latter read-register
error bit is additional to its two address/data contributions. Index/count,
tag and current/result storage are included. Combinational muxes/comparison
and decode are additional. These declaration counts are not synthesis cell
measurements. RAM mapping, address comparison width and reset fanout create
LOW default / MEDIUM maximum qualitative resource risk. No LUT/FF/BRAM/DSP,
Fmax, power, synthesis, PnR, STA or board measurement is claimed.

After LAST acceptance, a valid nonempty frame has exact first-valid latency
`2+3n+2C+2U+W` clock periods. U is the number of distinct addresses. For item i,
C adds i if it is the first occurrence; otherwise C adds one plus its first
occurrence index. W counts request-valid/not-ready edges and
response-ready/not-valid edges during processing. The controller-only part is
bounded by `n*n+4n+2`, at most **322 default / 1154 max**. Error/empty first-valid
latency is exactly one period after LAST. Subsequent nonfinal output transfers
produce next-valid one period later; always-ready transfers are two periods
apart. Input loading accepts one token per edge. Source gaps, external memory
waiting and output backpressure are unbounded; these internal bounds are not
unconditional system deadlines or throughput measurements.

## Offline use and frozen finite evidence

`files.f` is the complete production closure. `example/files.f` adds the fixed
default wrapper exposing every port. Root LICENSE/NOTICE apply. Run from this
package directory:

```text
iverilog -g2012 -Wall -tnull -s ram_read_gather -f files.f
iverilog -g2012 -Wall -tnull -s gather16 -f example/files.f
python -B run_tests.py
```

[TEST_PLAN.json](TEST_PLAN.json) freezes five N/A/D/T profiles 1/1/1/1,
3/5/5/3, 7/16/16/8, 16/32/32/8 and 32/64/64/32 before the first HDL tool.
The runner uses only Python standard library and local Icarus. Each compiler
or simulator child has a fixed 20-second limit. Timeout is terminal: no retry,
smaller fixture or increased limit. An ordinary failure archives its original
receipt and all source bytes before any same-matrix correction. Successful
matrices cannot be rerun by the runner.

The independent Python oracle uses an address dictionary with frame-dependent
data/error, insertion-order distinct requests, and ordered value lookup.
It does not model the RTL RAM scan. A separate first-occurrence operation-count
certificate checks exact internal latency, plus observed external waits. The
TB checks unique request order, one-outstanding ownership, every output field
and every computed packed row. It preoffers the actual next frozen input token
while work/output is blocked, holds all fields until handshake, and monitors
all four channels. Zero-latency offered responses are held through p_ready=0.
Cases include all small address words up to length four, all address bits,
empty/masked/error/overflow frames, capacity, duplicate read errors, complete
unique sets, repeated addresses across frames and deterministic traffic.

Sixteen immediate reset probes per profile cover all reachable states,
loading, pending/stalled external request, pending response, held status/data,
queued next source and partial replay (when N>1). Each reset is asserted at
the observed low boundary before another active edge. Both DUT and peer cancel
there. Each probe then completes two new same-address frames: successful data
then error/zero data, checking complete replay, RAM and one new physical read
per frame. N=1 excludes only the unreachable SCAN states. The default example
and eight named invalid-static elaborations are included in the 19-child
matrix. Actual outcomes, totals, all child stdout/stderr and exact current
source/plan hashes are recorded in [verification.json](verification.json).
Finite tests do not prove every legal history or parameter tuple. The example
is syntax-only; hardware remains HW_UNVERIFIED. Local LF policy was the first
file created and applies from the package's inception.

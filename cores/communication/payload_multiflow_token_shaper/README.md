# Payload multiflow token shaper

Stores one complete packet per flow, charges the exact number of asserted KEEP
bits, and releases only a packet whose complete byte cost is affordable. The
existing `multiflow_token_shaper` supplies independent clock-based buckets and
round-robin bypass of credit-poor flows. Payload data, including masked bytes,
is retained in per-flow synchronous RAM banks.

The first accepted ingress beat owns the full 32-bit flow ID and tag through
accepted LAST. Later flow/tag values are ignored. No prefix is published before
LAST. A stored packet becomes visible to the scheduler atomically; its entire
cost is debited exactly on `m_valid && m_ready && m_sop`. Prefetching, holding the
first output beat, admission acknowledgement and output LAST do not debit.
Once output starts, that flow remains locked through the actual LAST transfer.

## Interfaces and configuration

One clock; synchronous active-high reset at the public interface; no CE or CDC.
Every transfer is valid && ready. A source holds all payload fields while
blocked. Every ready/valid output is suppressed during reset. Backend RAM/FIFO
control uses its unchanged asynchronous active-low reset protocol; payload RAM
is never cleared. Reset flushes ownership, replies, descriptor state and output
buffering; all flows then require configuration.

Configuration fields and response codes match the existing descriptor shaper:
`c_flow`, enable, capacity, rate, initial tokens and tag. Each quantum of QUANTUM
clocks adds rate bytes, clamped at capacity. Configuration installs only when
the held successful response is acknowledged. Status 0 succeeds, 1 rejects a
full-ID flow outside FLOWS, and 2 rejects initial/rate above capacity or enabled
capacity zero. Rejected configuration has no effect. Rate zero and disabled
capacity zero are legal. Only FREE flows may be configured; a collecting,
complete, queued or transmitting flow blocks configuration until actual LAST
retires. A held configuration response also blocks packet start on its target.
At a simultaneous free-flow config/packet offer, configuration has priority.

Ingress accepts `s_data`, byte KEEP and LAST; zero KEEP beats still occupy a
payload slot. One shared collector receives one packet at a time, and each flow
owns at most one packet. Another flow may transmit while collection continues.
Oversize, disabled or invalid-flow packets are drained to LAST. There is no
abort input or timeout: a missing LAST needs reset. MAX_BEATS limits all accepted
beats, including empty ones. The packet cost is the sum of KEEP popcounts.

| a_status | Admission result |
| --- | --- |
| 0 | STORED: complete packet committed; this is not transmit completion |
| 1 | BAD_FLOW: first full 32-bit ID outside FLOWS |
| 2 | EMPTY: zero valid bytes |
| 3 | OVERSIZE: more than MAX_BEATS accepted beats |
| 4 | BAD_COST: positive packet bytes exceed the installed capacity |
| 5 | DISABLED: first flow is disabled |

Priority is BAD_FLOW, DISABLED, OVERSIZE, EMPTY, BAD_COST, STORED. The response
echoes the first flow/tag. a_bytes and a_beats saturate at MAX_BEATS*KEEP_W+1 and
MAX_BEATS+1. A held admission response blocks new ingress globally, while output
continues. Rejected packets release their slot and emit no payload.

Output preserves every DATA/KEEP word in order, with stable flow, first tag and
total valid-byte length on every beat; SOP and LAST mark the packet boundaries.
No flow interleaving occurs. Empty beats are preserved. The downstream must use
KEEP when interpreting byte data. No Ethernet, UDP or other wire format is
encoded. `faulted` is a reset-only diagnostic for unreachable dependency/result
invariant failures; normal backpressure or rejected input does not assert it.
After a backend fault, reset is required for further admission.

## Parameters and integration

| Parameter | Default | Supported |
| --- | --- | --- |
| FLOWS | 4 | 1..8 |
| DATA_W | 32 | 8,16,32,64 |
| MAX_BEATS | 512 | 1..512 |
| TOKEN_W | 16 | 1..24 |
| TAG_W | 8 | 1..16 |
| QUANTUM | 16 | 1..1024 |

MAX_BEATS*(DATA_W/8) must fit the unsigned TOKEN_W cost. Unsupported static
parameters fail elaboration. Counters retain one extra diagnostic value instead
of wrapping. files.f and example/files.f resolve from this package root and list
the three unchanged canonical dependencies explicitly. No download is needed.
`four_class_payload_tx` is an actual fixed default-parameter integration with
two-bit class IDs; its separate TB instantiates that exact wrapper.

## Finite qualification

Source-only authoring state: RTL_CANDIDATE, INTEGRATION_CANDIDATE, HW_UNVERIFIED.
The frozen plan permits exactly three independent model preparations, three
syntax checks, and four compile/sim pairs: 14 children, 11 HDL children, four
simulations. Profiles are singleton 1/8/1/1/1/1, ragged 3/16/5/4/3/3 and maximum
8/64/512/24/16/1024 (FLOWS/DATA_W/MAX_BEATS/TOKEN_W/TAG_W/QUANTUM), plus the
actual fixed example. No execution is permitted without root and independent
peer approval of exact source, runner, plan, seal and tool hashes.

The model independently classifies 12 complete packet fixtures per profile.
TBs compare every payload bit/KEEP, admission count, length, first metadata,
markers and held output. A public-configuration/public-SOP clock ledger checks
the existing bucket balances after every active edge. Tests cover zero KEEP,
boundary capacity, full/overfull buffers, invalid full IDs, disabled flow,
zero-rate underfunding, Q=3/Q=1024 positive-rate refill then eligible-flow bypass,
and five live reset predicates
with fresh recovery packets. Ragged/maximum require simultaneous different-bank
ingress write and output read. The singleton has one bank and one beat, so that
structural concurrency predicate does not apply.

The one-attempt runner executes archived source closure, records initial
simulation image SHA before Popen, and durably retains PID/terminal/raw evidence
before parsing. Each child has 20 seconds, tree helper 5 seconds, and one final
2-second target observation. Failure stops and preserves the attempt. There is
no automatic retry. No synthesis, PnR, STA, board test, PPA claim or historical
regression is authorized by this package.

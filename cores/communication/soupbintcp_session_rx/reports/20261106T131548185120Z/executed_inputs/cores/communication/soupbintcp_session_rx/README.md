# SoupBinTCP server receive session

`soupbintcp_session_rx` receives the ordered, reassembled byte stream from one
TCP connection. It owns SoupBinTCP framing, server-direction message validation,
login session/sequence decoding, implicit sequenced-message numbering and
atomic payload release. TCP/IP, sockets, retransmission, credentials, heartbeat
timers, reconnect transmission and higher-level ITCH decoding belong to peers.

Current state: RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED. No model,
HDL, synthesis, placement/routing, timing or hardware check has run for this IP.
The runner requires complete root/peer source review and a new unique gate.

## Contract

One clock, synchronous active-high reset, ordinary valid/ready, no CE or CDC.
Reset suppresses all public ready/valid immediately and cancels the connection,
partial frame, FIFO owner, pending payload and completion on its clock edge.
FIFO storage is not reset; pointer/valid reset hides all old bytes. The caller
must apply reset for every new TCP connection and after any closed/faulted
connection. A missing declared byte or blocked sink can wait indefinitely.

`s_data` is one TCP stream byte, with no segment boundary or LAST input. Logical
Soup packets may cross or share TCP segments. The first length-prefix byte's
`s_tag` owns the packet; subsequent tags are ignored. Every source holds all
offered fields until accepted. The core admits one entire packet owner at a
time, through completion retirement. No new input transfers on that retirement
edge; earliest admission is the following edge.

The two-byte big-endian length counts type plus body, excluding the prefix.
Length zero is a fatal framing error. Every nonzero declared length is fully
consumed, including rejected oversized packets, before its completion. There
is no delimiter scan, guessed resynchronization or TCP FIN input.

| Server type | Required length | Behavior |
|---|---:|---|
| `+` | 1..65535 | Ignore debug text, one successful completion, no session change |
| `A` | 31 | First non-debug login accepted: session10 then ASCII next-sequence20 |
| `J` | 2 | First non-debug login rejected, reason `A` or `S`, closes connection |
| `S` | 1..FIFO_DEPTH | Logged-in sequenced application message, possibly empty |
| `H` | 1 | Logged-in server heartbeat, no sequence advance |
| `Z` | 1 | Logged-in end-of-session, closes connection |

Client-direction `L/U/R/O` and unknown types reject. Repeated A/J after login,
or S/H/Z before login, reject. Closed/faulted connections cannot accept another
byte until reset. Debug is legal before login and while active. Once closed,
the endpoint does not admit even debug traffic; transport must reset/reconnect.

Session80 is opaque and preserved exactly; this core does not validate its
alphanumeric characters or authorize a requested session. ASCII sequence
requires leading spaces followed by at least one decimal digit, without signs,
embedded/trailing spaces or nondecimal bytes. Leading zeros are permitted.
Numeric values must be 1..2^64-1. A successful login supplies the actual initial
next sequence; no configuration, hidden seed or implicit first S is used.

Each accepted S, including empty payload, consumes one sequence. The message at
2^64-1 is delivered once, after which `exhausted=1` and next remains 2^64-1.
Further S rejects; H and Z remain valid. There is no modular wrap or confusion
between that retained value and a reusable sequence. A malformed/capacity frame
does not advance state, and latches fatal fault before later messages can be
incorrectly numbered. Recovery requires a new connection and login.

## Payload and completion

Only a complete, validated S can produce `m_valid`. Outputs are its body bytes
(type/prefix removed), with final-byte LAST, message sequence, session and first
tag. Empty S produces no payload beat but still has a completion. FIFO commit
precedes the first payload; reset can cancel a suffix already delivered, so
system-wide reset coordination is required. All output fields stay stable while
held. The complete payload retires before completion becomes valid.

`r_valid/r_ready` returns exactly one completion per captured logical packet:
status, type, declared length, declared payload bytes (length-1, or zero for
length zero), S message sequence (zero otherwise), post-frame next/session,
first tag, logged/closed/faulted/exhausted and successful J reason (zero otherwise).
All completion fields remain held. Declared payload count is not an emitted-byte
count for debug, control or rejected frames.

| Status | Meaning |
|---:|---|
|0|Success|
|1|Unknown or client-direction type|
|2|Zero length or wrong fixed control length|
|3|S exceeds FIFO capacity / unexpected internal FIFO overflow|
|4|Malformed/zero/out-of-range ASCII sequence or invalid J reason|
|5|Message incompatible with logged-in state|
|6|Another S after the last representable sequence|

Any nonzero status latches fault. Validation priority is type, fixed length,
S capacity, session state, exhaustion, then body fields. A rejected frame retains
the previous session/next/logged/exhausted snapshot and emits no payload.

## Architecture and closure

FIFO_DEPTH is a power of two in32..4096 (default128); TAG_W is1..32 (default8).
Unsupported configurations elaborate a named missing-module guard. Production
`files.f` has only the wrapper and a package-private MIT FIFO. That FIFO is the
unchanged upstream implementation except for its unique module name. No sibling
RTL, generated image, IP catalog or external network is needed to elaborate.

The real FIFO is FRAME_FIFO with last-beat bad-frame rollback. All supported
non-debug packets, including late-invalid login/J fields, reach that real commit
or drop boundary. Valid control frames are drained internally; S skips exactly
one stored type byte, then exposes payload. Rejected type/length/state/capacity
frames are drained without opening a FIFO frame. Debug needs no FIFO storage.

Within a frame the structure can accept one byte per clock without sink
backpressure, because a bounded frame fits an initially empty FIFO. Frame-level
service is capture then replay then held completion, so continuous wire-rate
traffic across frames is not claimed. With ready peers, the conservative source
budget is at most 2*length+12 clocks from first prefix admission to next owner
admission for a buffered packet; stalls add directly. This budget is architectural
and is not a measured timing or board claim.

RAM holds FIFO_DEPTH*10 bits (byte, LAST, bad flag), plus two read-pipeline words.
Session/sequence parsing adds bounded scalar state and a68-bit shift/add-by-ten
path. No multiplier, divider, DSP, CAM or unrolled per-byte processing is needed.
Default memory1280 bits, maximum40960 bits; FPGA RAM mapping and frequency have
not been measured. The likely paths are the decimal shift/add and FIFO control.

See ARCHITECTURE.md for semantic deduplication and SOURCES.md for fixed upstream
and protocol references. FINITE_PLAN.json specifies one preparation and nine HDL
children, with3 actual core/FIFO simulations. None has executed yet.

# MoldUDP64 to ITCH order events

`moldudp64_itch_rx` accepts a complete UDP payload, checks its MoldUDP64
message framing and configured session/sequence, and emits normalized ITCH5
order-book events. It supports Add A/F, Execute E/C, Cancel X, Delete D and
Replace U. A downstream order-ID table can reconstruct each resting order;
this endpoint does not maintain that table or an aggregated price book.

The independent capability is complete datagram ownership, atomic rejection,
message-count sequence management and variable-message replay. No external
message offsets, field-extraction commands or host packet preprocessing are
needed. The complete production closure is the single local RTL in `files.f`.

## Clock, configuration and input

One rising-edge clock, synchronous active-high `rst`, no CE or CDC. Public
ready/valid signals are suppressed while reset is high. Its active edge
cancels the current packet, held event and completion, clears configuration,
expected sequence and end state. RAM payload/read data are not reset; only
the completely captured current packet can be replayed. Reset during event
delivery can cancel a suffix of an already delivered packet; peers must
coordinate reset/recovery because there is no downstream rollback.

All transfers use ordinary `valid && ready`. Sources hold every associated
field until accepted; events and completion remain stable under arbitrary
stalls. There is one packet owner, from its first accepted byte through held
completion retirement. Input is blocked during validation/replay/completion.
There is no timeout; a missing input LAST or blocked sink can wait indefinitely.

`cfg_valid/cfg_ready` loads all ten session bytes and unsigned64 `cfg_next`
atomically while idle. No configuration response is needed. A simultaneous
configuration offer wins over a first payload byte; the byte must remain
offered until accepted. The caller supplies the expected first message from
its startup/recovery policy, including zero if desired. No first packet can
implicitly choose an epoch. Reconfiguration clears end state and is the only
way to replace an epoch without reset. Configuration cannot change in flight.

`s_data[7:0]` is one byte, `s_keep=1` on every byte, `s_last=1` only on the
datagram's final byte. The first transferred `s_tag` owns all packet results;
later transferred tags are ignored. Missing KEEP rejects the whole datagram.
An empty UDP payload represented by KEEP0/LAST1 is a framing error. A complete
Mold header has20 bytes; heartbeat/end packets are therefore nonempty.
No SOF, byte masks beyond KEEP, external address or memory response exists.

This contract matches the nonempty standard ready/valid payload side of the
existing `ethernet_udp/udp_payload_rx`; KEEP0 empty payloads are also drained
and rejected. Its Ethernet/IP/UDP validation must precede this core. There
is no Ethernet/FCS/IP/UDP checksum, multicast subscription, socket, replay
request transmitter or network authentication here. CE-qualified neighbors
require a real adapter. The example is an all-port default endpoint, not a
new physical/network integration qualification.

## MoldUDP64 acceptance and sequence state

All multibyte values are big endian. Session occupies bytes0..9, first
sequence10..17 and message count18..19. Each ordinary message has a two-byte
length excluding that length field. Zero-byte Mold messages are legal and
skipped. Unknown nonempty ITCH types are skipped by the exact length, without
inventing an event or applying ITCH field validation to their bodies. Every
ordinary message, including unknown/empty ones, consumes one sequence number.

Count0 is a heartbeat. Count65535 is end-of-session, with no message blocks;
both carry the next expected sequence and do not advance it. A good end
latches end state; data packets then reject until configuration/reset.
Repeated matching end packets and matching heartbeats remain accepted.
There is no automatic day/session transition or timer-based close.

The complete packet must match configured session and **exact** expected
sequence. Stale, overlapping and future packets emit no events and do not
advance state. A future packet is not buffered for resequencing. The caller
uses completion sequence/next fields to request missing data externally or
explicitly reseed after recovery. Partial overlap is rejected as a whole.

The unsigned65 sum `first_sequence + message_count` must fit unsigned64.
Overflow rejects, with no modular wrap, exhaustion sentinel or hidden epoch
change. Thus a next value of2^64-1 permits heartbeat/end but no data whose
following expected value would be2^64. This is an explicit bounded policy.

Length/count mismatch, truncation and any trailing bytes reject. Supported
ITCH types must have exactly the lengths below; A/F side must be ASCII B/S,
and C printable must be ASCII Y/N. The entire packet is checked before any
event: a bad later message cannot leak an earlier good event. Oversized
packets stop RAM writes at capacity, saturate their byte counter and drain
through LAST. Storage never aliases an oversized tail onto retained bytes.

## Events and field meaning

| Type | Length | Event fields beyond the common header/order |
| --- | ---: | --- |
| A |36|sell, quantity, stock, price|
| F |40|A fields plus attribution|
| E |31|executed quantity, match; printable=1|
| C |36|executed quantity, match, printable, execution price|
| X |23|cancelled quantity|
| D |19|no additional payload|
| U |35|new order reference, replacement quantity and price|

Every event carries original ASCII `m_type`, unsigned16 stock locate/tracking,
unsigned48 timestamp, unsigned64 original order reference and its exact
unsigned64 `m_sequence`. Timestamp is raw **nanoseconds since midnight**,
with no clock conversion, date reconstruction or range/monotonicity policing.
All numeric message fields retain their full unsigned wire bits. Quantity is
unsigned32 shares; price is unsigned32 in implied decimal4 units (1/10000).
Price is not a binary Q format and is not converted or saturated. The decoder
does not enforce the feed's advertised price ceiling or business rules such
as order existence, remaining quantity or reference uniqueness.

Stock64/attribution32 retain ASCII bytes, first wire byte in the high byte,
including right padding spaces. `m_sell=0/1` means B/S only on A/F. E/C/X/D/U
do not carry side/stock, so the consumer retains these from the original Add.
U's new reference becomes the future order ID; the original reference remains
in `m_order`. Every absent optional field is zero. Explicit price/stock/
attribution/match validity flags distinguish absent fields from zero values.
Printable has meaning only for E/C; it does not alter order-book removal.

Events retain message order. `m_last` marks the final **emitted** event of the
packet even when unknown/empty messages follow it. An all-skipped/control or
rejected packet emits no event, and therefore no event LAST. `m_tag` is the
first-byte tag. The separate completion is the definitive packet boundary.

## Completion and commit

`rsp_session/sequence/messages` echo the captured header, or all zero for
packets shorter than20 bytes. `rsp_events` counts actual event transfers.
`rsp_next` and `rsp_end` describe retained state after the packet; `rsp_tag`
echoes the first-byte tag. Every field remains held until `rsp_ready`.

| Status | Meaning, in decreasing validation priority |
| ---: | --- |
|2|Capacity exceeded|
|3|KEEP, truncation, message-block framing, extra bytes|
|4|Supported ITCH length or A/F/C enumeration mismatch|
|1|No configured epoch|
|5|Session mismatch|
|6|Packet sequence below expected|
|7|Packet sequence above expected (gap)|
|8|Data after accepted end-of-session|
|9|Unsigned sequence-sum overflow|
|0|Success, including skipped messages and controls|

Errors have zero events and leave state unchanged. Success commits next/end
only after every event has externally retired and all message blocks have
been replayed/skipped. Completion cannot race ahead of a stalled event. Its
retirement frees the owner; a new byte/configuration first transfers on the
following edge. There is no independent configuration/status read port.

## Architecture, schedule and limits

`MAX_PACKET_BYTES` defaults2048, supports every integer64..4096; `TAG_W`
defaults8, supports1..32. Derived address width defaults clog2(capacity);
an explicit AW must cover capacity and lie1..12. Invalid static settings
reference a named missing parameter-error module at elaboration. Runtime
capacity is the static byte limit, not a guessed network MTU.

The packet RAM has8*MAX_PACKET_BYTES bits:16384 default/32768 maximum. Capture
has one write per accepted byte and no RAM reset. Replay has a synchronous
read-request edge and a consume edge; it reads two length bytes plus all body
bytes for a selected type, or only the type byte for an unsupported body.
Zero-length bodies need only the two length reads. Read/write phases never
overlap; no particular read-during-write device mode is assumed. A320-bit
message buffer and held event/control fields use registers. No event array,
order table, multiplier, divider, DSP or vendor primitive is introduced.
Resource risk is **MEDIUM**: variable byte write/select, wide metadata and
RAM inference/packing require physical review. Counts are source storage,
not measured LUT/FF/BRAM, Fmax, power or board throughput.

Capture can accept consecutive bytes at one per clock. From the final input
edge L, a rejected packet presents response after L+1; a good control after
L+2. For a first selected body of N bytes without preceding skipped blocks,
event valid rises after L+2*N+6 and earliest transfer is L+2*N+7. Between two
selected messages of next-body length N, an always-ready transfer gap is
2*N+6 clocks. Each intervening nonempty unknown/empty body adds6/4 clocks
respectively. Following the last event transfer E with no trailing skipped
messages, completion is valid after E+1. Every earliest transfer is one edge
after valid appears. Stalls add directly; there is no unconditional deadline.
This buffered serial endpoint has no continuous wire-rate/10GbE claim.

## Offline finite evidence

Resolve both file lists from this package root. `example/files.f` adds
`itch_order_events`, a complete named-port endpoint. No sibling RTL, generated
ROM or external service is needed to elaborate or use the production core.
Python and repository-local OSS-suite Icarus/vvp are used only for checks.

`python -B run_checks.py` freezes all seven executable/file-list inputs and
then fixed vectors before launching default/max/example syntax plus three
compile/simulation pairs. Each child has a20-second hard watchdog and bounded
process-tree cleanup; failure stops later launches. An existing receipt
prevents automatic retries. No successful image or external reference cache
is deleted by this runner; ignored .work is left for orchestrator closeout.

The independent Python oracle unpacks whole datagrams, walks byte slices and
decodes direct specification fields, without a receive/replay FSM, RAM index
or HDL helper. A hand-calculated Add anchor pins byte order and units. Profiles
are64/TAG1,257/TAG9 and4096/TAG32, including actual maximum-memory simulation.
Fixtures include all seven types, unknown/empty messages, exact capacity and
one-byte overflow, strict gap/stale/session handling and recovery, heartbeat/
end/repeated end, zero/high64 sequence and overflow, malformed headers/counts/
lengths/trailing bytes, late bad messages, enum errors, source gaps, downstream
stalls and four live reset phases followed by reconfiguration/fresh traffic.
All public event fields and completion values are compared. This finite set
does not establish every traffic schedule or a complete exchange feed handler.

The first and only run `reports/20261105T183914899205Z/results.json` passed all
nine children:306 completed packets,139 retired events,36 configurations,
152 held-event cycles,1530 held-completion cycles and15 reset episodes
(12 live). Normal packet payloads total22765 accepted bytes; cancellation
probes are additional. Seven current executable/file-list sources match the
exact pre-tool archived copies. Raw logs, vector hashes and complete source
mapping are sealed in `B35_DELIVERY.json` and `QUALIFICATION.md`.
States are LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED;
LINT_PASS here denotes Icarus syntax/elaboration. No synthesis, PnR, STA,
board run, inherited regression or exchange conformance suite was run.

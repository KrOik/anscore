# MoldUDP64 recovery manager

Original Apache-2.0 RTL for bounded missing-prefix request control. It records a
per-session target and one outstanding request. `example/recovering_itch_rx.sv`
connects the existing strict MoldUDP64/ITCH receiver to this manager and emits
the actual 20-byte big-endian MoldUDP64 request header. No shared RTL is changed.

Current maturity: RTL_CANDIDATE, INTEGRATION_CANDIDATE, HW_UNVERIFIED. The finite
plan must pass independent source review before any HDL child executes. No
synthesis, placement/routing, STA, board test or old regression is authorized.

## Interface and ordering

All ports use one clock, synchronous active-high reset and ordinary valid/ready
transfers. There is no CE or CDC. A command transfers on `c_valid && c_ready`.
The core owns the command, RAM transaction and result until `r_valid && r_ready`.
All result bits remain stable while held. There is no fall-through admission:
the next command can transfer on the clock following result retirement. Reset
discards metadata/results and invalidates all contexts; payload RAM is unreset
and hidden by the configured bitmap. The reused RAM receives `rst_n=!rst` and
`clk_en=1`.

Parameters: CONTEXTS 1..32 (default16, including non-powers of two), REQUEST_MAX
1..65534 (default1024), TAG_W 1..32 (default8). Public context indices remain32
bits and are checked before narrowing. Session is80 bits. Sequence, next,
target and outstanding exclusive end are full unsigned64-bit integers with
ordinary numeric ordering, not modular wraparound. Tags are opaque echoes.

| c_op | Operation | Effect |
| --- | --- | --- |
| 0 | CONFIG | Open/reseed context with session and c_next; discard old gap/request/EOF |
| 1 | HINT | Extend target to max(target, endpoint) from rejected valid datagram |
| 2 | PROGRESS | Advance next to c_next; actual advance clears outstanding |
| 3 | ISSUE | Emit bounded request from next if gap exists and none outstanding |
| 4 | RETRY | Re-emit the original outstanding request |
| 5 | GET | Return current snapshot |
| 6 | CLEAR_CTX | Invalidate selected context |
| 7 | END_SESSION | Close accepted EOF, target=next, clear outstanding |
| 8 | CLEAR_ALL | Invalidate all contexts; ignores context index |
| 9..15 | Invalid | BAD_OP, no mutation |

HINT uses c_sequence+c_messages with a65-bit overflow check. Counts0 (heartbeat)
and65535 (EOF) instead use endpoint=c_sequence. The exclusive endpoint includes
the dropped future datagram itself: the strict receiver has no future-payload
buffer and rejects the entire packet. HINT need not identify an outstanding
request; repeated hints can extend the target without duplicate issuance.
Equal PROGRESS succeeds without changing state; backwards progress fails.
Actual progress always clears outstanding, including a partial reply, because
a server may return fewer complete messages than requested in one UDP packet.
ISSUE emits [next,min(target,next+REQUEST_MAX)). RETRY preserves that descriptor;
external timeout/retry policy supplies the trigger. END_SESSION mirrors the
existing receiver's accepted EOF policy; CONFIG opens the next epoch.

| r_status | Meaning |
| --- | --- |
| 0 | OK |
| 1 | NOT_CONFIGURED |
| 2 | BAD_CONTEXT |
| 3 | BAD_RANGE (ordinary hint endpoint overflow) |
| 4 | STALE_PROGRESS |
| 5 | NO_ADVANCE (hint target unchanged / ISSUE no gap) |
| 6 | OUTSTANDING (ISSUE suppressed) |
| 7 | NO_OUTSTANDING (RETRY) |
| 8 | CLOSED |
| 9 | BAD_OP |
| 10 | BACKEND_FAULT |

Ordinary errors do not mutate state. GET and errors on configured rows return
the retained snapshot. Invalid op/context, unconfigured and clear responses
return a zero snapshot. `r_emit` alone marks a request descriptor; otherwise
request sequence/count are zero. `r_until` is the outstanding exclusive end and
is zero when none outstanding. Repeated END_SESSION succeeds. RAM/invariant
faults produce BACKEND_FAULT; no rollback guarantee is made for an external
hardware memory fault. There is no public fault injection interface.

## Actual receiver/request example

The example fixes the existing receiver's packet RAM at2048 bytes and uses one
manager context. Priority at idle is configuration, explicit retry, then packet.
Configuration programs both modules, then holds a completion. Every original
normalized ITCH event field is forwarded unchanged. The receiver retires its
packet completion only after all events retire. The wrapper then performs:

- receiver status0: PROGRESS, or END_SESSION for accepted EOF;
- receiver status6/7 (stale/overlap/future): HINT;
- other receiver errors: completion with no manager mutation;
- successful/nonadvancing HINT or PROGRESS: ISSUE.

On an emitted descriptor, `request_valid/data/last/tag` serializes
session80|sequence64|count16, big-endian, exactly20 bytes, LAST at byte19. It is
a UDP payload header; networking/UDP transport belongs to the caller. Manager
response ownership is held through the final request byte. Public completion
then remains held until accepted. A blocked final event, request byte or
completion cannot admit configuration, retry or another packet. Packet and
request tags are the first input-byte tag; retry/config have their own tags.

`rsp_kind`:0 config,1 packet,2 retry. `rsp_status` is the unchanged receiver
status for packets, otherwise0. `rsp_recovery_status` is the latest manager
status for this operation (0 for a packet rejected before management).
`rsp_requested` indicates that this operation emitted a complete request frame.
`recovery_*` holds the last observed manager snapshot, also retained on parse
errors. Packet rsp metadata is the original receiver completion; retry metadata
uses manager session/next/closed and zero sequence/messages/events.

This is a bounded metadata/request adapter, not a complete recovery client. It
does not implement sockets, IP/UDP transmission, timers, authentication,
reliable delivery, multiple live packets, payload reordering or merging.
Whole-packet overlap rejection remains unchanged, so progress can re-request a
missing suffix. Accepted EOF closes the epoch; full protocol EOF re-request
persistence is outside the existing receiver's policy.

## Architecture feasibility and cycle budget

One reused synchronous single-port RAM stores CONTEXTS rows of280 bits:
pad6|closed1|outstanding1|session80|next64|target64|until64. Default storage4480
bits; maximum8960 bits, plus16/32 configured bits and bounded scalar state.
No CAM, hash table, payload RAM, DSP, multiplier, divider or unrolled context
scan is added. Private RAM read/write handshakes are serialized. First result
valid is at most5 clocks after command acceptance, independent of context
count. Held results extend ownership indefinitely under backpressure.

The example has16664 payload bits (2048*8+280). After receiver completion, a
successful managed packet uses two manager operations, each bounded by5 clocks,
plus wrapper send/wait state transitions; request serialization is20 always-ready
clocks. Completion becomes valid within40 clocks after receiver completion
retirement when all request bytes are accepted immediately. Receiver byte
capture/event replay costs remain those of its existing implementation.
Resource risk LOW for metadata, MEDIUM for the fixed packet RAM and variable
byte-select formatter. These are structural judgments, not measured area,
frequency, power or hardware throughput.

## Finite verification

`run_checks.py --write-plan` only hashes files/tools and writes the finite plan;
it does not import or call the oracle. After C and root review, the one approved
execution archives all exact sources/dependencies and the plan before three
independent dictionary/integer oracle calls. All three vector files are frozen
before the first HDL child. A durable INCOMPLETE receipt precedes archival;
every child has a durable active checkpoint and raw stdout/stderr hashes.
Source, tool, plan and vector hashes are checked before each child and at end.

The plan is3 syntax checks plus3 core compile/sim pairs and1 actual example
compile/sim pair:11 children,4 simulations. Profiles (CONTEXTS,REQUEST_MAX,TAG_W)
are(1,1,1),(5,7,8),(32,65534,32). Each child is limited to20 seconds, with process
tree termination5 seconds and drain2 seconds. First failure stops; no retry,
automatic repair, or successful-profile rerun. No successful state is claimed
until raw evidence and exact coverage counts agree.

Core vectors cover all public operations, context bounds/high bits, all80/64
bit high values, ordinary overflow versus special-count endpoints, duplicate
hint/ISSUE suppression, explicit retry identity, partial progress, epochs,
clear, EOF and deterministic interleaving. Every checked response is stalled6
clocks with a live future GET offered. That GET stays valid through actual
admission and its independent model snapshot is checked, held6 clocks and
retired. Three additional resets interrupt
configuration before RAM access, during access, and with its result held;
post-reset GET must be unconfigured. `commands` counts checked responses.

Actual example sends binary Mold headers/message blocks, one normalized Add
Order, zero-length unknown messages, future/stale/overlap/heartbeat/EOF,
overflow and partial replies. It checks all20 request bytes and every key event
field. Final event/request/completion stalls offer live future input. Resets
occur in capture, config management, held response, held event and final request
byte. Counters count8 accepted configs (one aborted),15 fully submitted packets,
5 retries (one aborted),6 complete requests plus19 retired bytes of the aborted
request (139 bytes),1 retired event,24 checked completions and6 resets.

See `ARCHITECTURE.md` for semantic dedup and `REFERENCES.md` for fixed read-only
protocol/upstream references. `files.f` and `example/files.f` are offline source
closures using existing repository RTL.

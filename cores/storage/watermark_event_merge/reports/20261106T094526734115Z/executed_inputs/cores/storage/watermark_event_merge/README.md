# Watermark-aware event-time feed merge

`watermark_event_merge` retains one complete pending event for each input feed
and releases the earliest safe event. It combines an unchanged keyed deadline
scheduler with separate synchronous payload and feed-metadata RAMs. A producer
can leave a feed silent while explicitly advancing its lower bound. Silence,
packet completion and heartbeat arrival never imply progress by themselves.

Status: RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED. No model or HDL
execution is authorized until C source review and the root's exact finite-plan
gate. Physical implementation and inherited regressions are excluded.

## Domains and proof obligations

FEEDS is1..8 (default4), DATA_W is8..512 in multiples of8 (default128), and
TAG_W is1..32 (default8). Unsupported settings fail elaboration. Public feed
indices remain unsigned32 and are checked before narrowing. Time and sequence
are full unsigned64 integers, including0 and all ones, with ordinary numeric
ordering. Payload/tag are opaque exact bits. There is no implicit clock unit,
wraparound, timestamp sentinel, conversion, rounding or host-side sort.

Every feed starts open after reset/CLEAR, with no previous event, watermark
or buffered head. EVENT time must be nondecreasing within its feed, and sequence
must be strictly increasing; gaps in sequence are legal. The first sequence
may be any value. Once sequence reaches all ones, that feed cannot accept
another event in this epoch. These checks concern accepted events, including
ones already popped. There is no cross-feed sequence comparison or deduplication.

WATERMARK(W) is an **inclusive lower bound**: every subsequently accepted event
from that feed must have time>=W. Equal watermarks are idempotent and decreasing
watermarks reject. A watermark may pass an already buffered head, since that
head was accepted before the promise. It cannot discard or retimestamp it.

POP selects the minimum buffered `(time, unsigned feed index)`. Per-feed sequence
order is preserved, including equal times. To release candidate time t, **every
other feed** must have a buffered head, be permanently EOS, or have an explicit
watermark strictly greater than t. An empty open feed with watermark equal to t
still blocks, even if its feed ID would make a tie harmless. This conservative
rule prevents unsafe early release and requires no counter arithmetic. An empty
feed without any watermark always blocks a nonempty candidate. If no head exists,
POP returns EMPTY; there is no invented data or implicit wait timeout.

EOS permanently closes one feed to EVENT/WATERMARK until reset/CLEAR. Repeated EOS
is successful. Its already buffered head remains eligible and drains normally.
All-ones timestamps can drain once every missing feed is EOS; no finite watermark
can exceed them. `r_end` means all feeds are EOS and no buffered heads remain.
It is separate from EMPTY, since an empty open merge may receive future events.

## Commands, outputs and errors

| c_op | Command | Used fields beyond op/tag |
|---:|---|---|
|0|EVENT|feed,time,sequence,data|
|1|WATERMARK|feed,time|
|2|EOS|feed|
|3|POP|none|
|4|GET|feed|
|5|CLEAR|none|
|6|INVALIDATE|none|
|7..15|BAD_OP|none|

Every accepted command has exactly one result unless reset cancels it. `r_op`
and `r_tag` echo the command. `r_heads` is the post-command head count, `r_end`
the post-command end condition, and `faulted` the sticky invalid-epoch state.
These remain stable during a held result because the owner blocks all commands.
Successful POP returns the chosen feed/time/sequence/payload. WAIT_FEED returns
the candidate time and the lowest blocking `r_blocked_feed`, with payload and
sequence0 and feed0. Every other non-POP result has time/sequence/payload0.

Valid-index EVENT/WATERMARK/EOS/GET results, including their ordinary errors,
return the selected `r_feed`, its post-command `r_head/r_closed`. Successful
GET additionally returns presence flags and exact previous time/sequence and
watermark; missing metadata is canonical0. Other operations return these GET
fields0. Successful POP has r_head0 and the chosen feed's closed state. Invalid
feed/op/state, EMPTY, CLEAR, INVALIDATE and backend faults have zero feed flags
except that a backend fault may retain the already captured valid-index flags;
those flags have no recovery meaning while faulted. Unused result fields are0.

| Status | Meaning |
|---:|---|
|0|OK|
|1|BAD_OP|
|2|BAD_FEED|
|3|CLOSED|
|4|HEAD_FULL|
|5|STALE_SEQUENCE|
|6|TIME_BACKWARDS|
|7|BELOW_WATERMARK|
|8|WATERMARK_BACKWARDS|
|9|EMPTY|
|10|WAIT_FEED|
|11|INVALID_STATE|
|12|BACKEND_FAULT|

BAD_OP is checked first. CLEAR/INVALIDATE remain available while faulted. Other
commands then check invalid state; POP ignores feed, while feed commands check
the full index. EOS is idempotent, GET observes a closed feed, other feed updates
reject CLOSED. EVENT then checks HEAD_FULL, previous sequence, previous time and
watermark, in that order. Ordinary errors preserve all state. Internal RAM or
calendar inconsistencies set sticky faulted and return BACKEND_FAULT; private
writes may already have completed. There is no rollback or automatic repair.
CLEAR empties the calendar and invalidates metadata, then opens every feed afresh.

## Clock, ownership and reset

One rising-edge clock, synchronous high rst, ordinary ready/valid, no CE or CDC.
Sources hold valid and all fields until accepted/reset; results hold every field
under arbitrary backpressure. One command owns the calendar, both RAMs and result
through retirement. No new command transfers on the retirement edge. POP reads
the temporal minimum, proves feed safety, captures the payload, and only then
claims that same calendar event. No other client can alter the chosen record.

Mutations finish before first result-valid. Result ACK retires a completed
mutation rather than committing it. Reset cancels held results and the entire
epoch, so an already claimed event may be lost; peers must coordinate/replay.
Reset immediately masks public ready/valid, and an asserted active edge clears
ownership/control. Payload/metadata RAM are unreset and hidden by validity bits.
The calendar serially clears F rows before command-ready returns. The private
shared RAM uses rst_n=!rst and clk_en=1; reset must span an active edge.

## Real dependencies, budget and finite gate

`files.f` resolves from this package and lists only the unchanged canonical
`cip_sync_sp_ram`, unchanged `ram_deadline_scheduler`, and new core. There are
no includes, ROMs, generated RTL, external memory or network runtime dependencies.
The complete two-decoder example is described below. No shared RTL is edited.
SOURCES.md records full-tree semantic dedup
and the fixed external source/license inspection.

See ARCHITECTURE.md for RAM/ownership/service reasoning. A source-only frozen
finite plan and independent review precede any model preparation or HDL child.
Numerical planning calls are0. New oracle preparations execute only as isolated
archived children; every child has20s hard execution,5s tree termination and2s
drain, immediate fail-stop, no automatic retry. No synthesis/PnR/STA/board/PPA,
old runner/model/checker import, inherited regression, cleanup, staging or commit.

## Actual two-feed ITCH composition

`example/dual_itch_time_merge.sv` instantiates two unchanged strict
`moldudp64_itch_rx` decoders (2048-byte packet RAM each) and the actual merge at
FEEDS2/DATA_W512. Each normalized event is captured before submitting EVENT.
The wrapper tracks its two owned head slots, fairly chooses available decoded
events, and automatically attempts POP when a head exists. Admin control wins
at an idle owner boundary; arbitrary admin traffic can starve internal service.
Held event/admin/error output prevents another owner crossing it. A real blocked
admin offer must stay asserted through its later acceptance. Packet completions
are independent per decoder and forwarded unchanged, including all session,
message/event count, next-sequence, EOF, status and tag fields. Packet completion
does not mean its events have already retired from the chronological merge.

The packed dual byte inputs use feed0 in the least significant slice, with
independent valid/ready/keep/last and tags. Each decoder may be configured exactly
once after global reset; its cfg_ready then stays low until the next reset.
The example exposes no CLEAR or reconfiguration of an active epoch. Reset both
upstream sources and consumers together to cancel outstanding packet obligations
and start a new session. Configuring a source does not manufacture a watermark.

Admin a_op0 WATERMARK,1 EOS,2 GET,3 INVALIDATE maps to the corresponding core
command;4..7 returns BAD_OP. Full feed32/time64 and tag are preserved. Every
admin has one held z result echoing a_op/tag and the core status/snapshot.
Watermark/EOS are explicit caller promises and are **never inferred** from a
Mold heartbeat, packet completion, a missing packet or an ITCH event timestamp.
The caller must establish feed completion/progress externally. EOS with queued
unsubmitted decoder events will cause those later EVENTs to reject and isolate;
the caller must drain them before EOS. Packet errors do not automatically advance
watermarks or repair loss. This is not an A/B redundant-feed deduplicator.

Merged output supplies feed1, timestamp64 (exact zero-extension of ITCH48),
sequence64 and data512. Low `399+TAG_W` payload bits are, from MSB to LSB:
`type8,locate16,tracking16,order64,new_order64,quantity32,price32,stock64,`
`attribution32,match64,sell1,printable1,price_valid1,stock_valid1,`
`attribution_valid1,match_valid1,packet_last1,original_tag[TAG_W]`.
Upper payload bits are0. No normalized field, validity marker, packet-last or
original tag is truncated or replaced. Sequence can skip unsupported/empty Mold
messages; the merge requires strict increase, not contiguous numbering.

A rejected internal EVENT or unexpected POP error causes explicit INVALIDATE
before a held error result. It reports the original rejection status/feed/tag,
then admits only external admin until reset. Earlier retired events remain
visible and no rollback is attempted. This failure path stops new packet bytes
and decoded events; sources may need coordinated reset to cancel blocked offers.

The fixed example TB uses real big-endian Mold packets and Add messages, checks
every decoded output field, held outputs, actual future admin offers, silent-feed
withholding, inclusive-equal versus strict-greater watermarks, repeated equal-time
feed-ID priority, EOS draining, source-time isolation and reset cancellation of
a held event. No mock decoder, precomputed RTL response, external driver or
per-packet host field extraction substitutes for either real receiver.

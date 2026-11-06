# Nasdaq OUCH 4.2 server receiver

Original byte-stream decoder for the October 2025 OUCH 4.2 server messages
S/A/U/C/E/J. It publishes one atomic event after a complete framed message.
The included `soupbintcp_ouch42_rx` actually instantiates the B45 canonical
SoupBinTCP receiver and its MIT upstream frame FIFO. It joins their completions
so a held application result blocks every later Soup frame, including control.

| Type | Message | Exact bytes |
|---|---|---:|
| S | System event | 10 |
| A | Accepted | 66 |
| U | Replaced | 80 |
| C | Canceled/reduced | 28 |
| E | Executed | 40 |
| J | Rejected | 24 |

Other OUCH messages, including D/B/G/P/I/T/M and all client-bound requests, are
outside this subset and return BAD_TYPE. This is wire normalization only: no
account state, token uniqueness tracking, order matching, replay deduplication,
financial accounting, TCP stack, socket, timer or trading decision is provided.
ITCH is market-wide order information; this input reports one OUCH account's
own order lifecycle. An accepted/replaced state D can already be dead, a C share
amount is incremental reduction, and E shares are incremental executions. The
decoder does not infer remaining quantity or reject an otherwise valid raw
unsigned value because of an order-entry business rule.

All ports share one clock. `rst` is synchronous active high and immediately
masks ready/valid. Reset cancels the current frame/result at the next rising
edge. Payload storage is not reset and no unfilled byte is exposed. TAG_W is
1..32 (default8); unsupported values elaborate a named missing module.

Standalone input is `s_valid/s_ready/s_data/s_last/s_tag`. A frame has at least
one beat and exactly one final LAST. The first accepted byte owns the tag;
later byte tags are ignored. A missing LAST keeps draining indefinitely; no
timeout or implicit resynchronization exists. The first80 bytes are cached;
longer frames are drained through LAST without more storage. `r_length`
saturates at65535. A held result blocks input. A new frame can start after
result retirement; an always-ready N-byte frame has start spacing N+2 clocks.

Result is `r_valid/r_ready`, `r_status`, raw first-byte `r_type`, saturated
`r_length`, first-byte `r_tag`, and the720-bit `r_event` record below. All stay
stable during a stall. Values outside result valid are unspecified. Status is
0 OK,1 BAD_TYPE,2 BAD_LENGTH,3 BAD_FIELD. Priority is unsupported type, then
exact length, then checked field. Any error zeros the entire event record.
The decoder continues after an error without reset.

Schema validation intentionally checks S event S/E, A/U side B/S/T/E and order
state L/D, C reason A..Z, and J reason A..Z/a..z. J's lowercase risk reasons are
present in the current specification. Other alpha/enumeration fields remain
opaque bytes, including new liquidity flags. Tokens, stock and firm preserve
all bytes without trimming, case conversion or ASCII validation. This contract
does not certify every field against venue business rules or validate padding.

`r_event` is a fixed unsigned packed ABI, most-significant wire byte first.
Every field absent from a message is zero, including previous token outside U.
S only fills timestamp/event_code. A/U fill timestamp/token and the common
side..state fields plus bbo. U's token is the replacement, previous_token is
the replaced token. C fills timestamp/token/shares/reason. E fills
timestamp/token/shares/price/liquidity/match. J fills timestamp/token/reason.

| Field | Bits | Meaning |
|---|---|---|
| timestamp | 719:656 | unsigned64, nanoseconds after midnight, no range filter |
| token | 655:544 | raw14 bytes |
| previous_token | 543:432 | raw14 bytes, U only |
| side | 431:424 | raw byte |
| shares | 423:392 | unsigned32, type-dependent quantity |
| stock | 391:328 | raw8 bytes |
| price | 327:296 | unsigned32, decimal4 price units, special values preserved |
| time_in_force | 295:264 | unsigned32 seconds/special values |
| firm | 263:232 | raw4 bytes |
| display | 231:224 | raw byte |
| order_reference | 223:160 | unsigned64 |
| capacity | 159:152 | raw byte |
| sweep | 151:144 | raw byte |
| minimum_quantity | 143:112 | unsigned32 |
| cross | 111:104 | raw byte |
| order_state | 103:96 | raw L/D byte |
| bbo | 95:88 | raw byte |
| reason | 87:80 | C/J raw reason |
| event_code | 79:72 | S event |
| liquidity | 71:64 | E raw liquidity |
| match | 63:0 | E unsigned64 match number |

`files.f` is the standalone source list, relative to this package directory.
`example/files.f` also includes the actual Soup source/FIFO from B45. Do not
substitute its preserved pre-followup RTL. Soup FIFO_DEPTH remains a power of
two32..4096. The wrapper defaults to128; depth>=128 can carry every supported
OUCH message (the longest needs81 Soup bytes including Soup type). A smaller
legal Soup depth can produce a fatal Soup CAPACITY before OUCH decoding.

The wrapper exposes the Soup status/type/reason/length, session/sequence/next,
tag and state flags unchanged. `r_is_ouch` is true only for a successful Soup S;
for this result the OUCH status/type/length and event describe its payload.
An empty Soup S produces OUCH BAD_LENGTH,type0,length0,event0 with no decoder
input beat. Non-OUCH controls and failed Soup frames have is_ouch0 and zero
OUCH fields. Soup failures preserve Soup's fatal-until-reset policy. A malformed
OUCH payload consumes its sequence and returns an error while Soup remains
usable. Neither error implies a retry. Reset resets both modules together.

Source-only status: RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED.
The finite source plan has one preparation child and15 HDL children, including
five simulations: three tag-width core profiles and two actual Soup profiles.
Root and independent peer must approve the exact plan/seal before execution.
No model, HDL or helper has run. No synthesis, PnR, STA, hardware or PPA claim.

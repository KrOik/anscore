# B45 scope and feasibility

Baseline a0602fb2dac20db7c524297371a19f5f580980df. Whole-repository searches
covered SoupBinTCP/soup.bin, login accepted, sequenced data, ASCII sequence/TCP
framing and module names, across Markdown, manifests and Verilog/SystemVerilog.
No existing SoupBinTCP server-session capability or axis_fifo module was found.
No AGENTS.md was found by repository file inventory.

Neighbor review:

- moldudp64_itch_rx owns one UDP datagram, explicit binary sequence/count and
  ITCH field decoding. It cannot frame an arbitrary TCP stream or seed implicit
  packet numbers from a20-character ASCII login response.
- moldudp64_recovery_manager manages missing UDP ranges and request headers;
  it does not authenticate/login a TCP feed or receive Soup logical packets.
- ethernet_udp/udp_payload_rx terminates UDP payloads; TCP reassembly and Soup
  are not implemented there. Generic FIFOs/byte utilities do not own a session.
- itch_order_state, itch_l2_delta_book, multi_venue_quote_state and
  price_level_order_book maintain application state after message decoding;
  this IP supplies a distinct transport-session boundary.

The new capability is independent of parameter selection: variable-length TCP
logical packet ownership, direction/control legality, full ASCII next-sequence
interpretation, active/terminal/fault state, and atomic FIFO-published message
payload. Session IDs are opaque, and caller-owned TCP remains an explicit scope
boundary. Source review may change this candidate before execution.

Candidate comparison: speculative streaming would publish incomplete application
messages and require downstream rollback; a custom payload RAM would duplicate
mature frame-commit logic. The chosen single-owner upstream frame FIFO makes
commit/drop observable and bounds memory. Serial capture/replay trades total
service rate for small memory/control and clear backpressure. Debug bypass avoids
blocking on arbitrarily large ignored text. Fixed maximum admitted S length is a
local capacity policy, not a claim that the Soup specification sets that limit.

All arithmetic is unsigned integer. Prefix/body counters are16-bit; accepted
length cannot exceed65535. S payload count is length-1. The decimal intermediate
is68-bit because 10*(2^64-1)+9 <2^68. Overflow is tested before narrowing; a
sticky format error prevents a later digit from legitimizing a failed value.
Sequence max uses an explicit exhausted flag, preserving the final legal number.
FIFO pointers/ports/pipeline remain those of the pinned upstream implementation.

Finite candidate checks use DEPTH/TAG (32,1),(128,8),(4096,32), exact-capacity S,
one-byte and65535-byte oversized S,65535-byte debug, all supported controls,
wrong directions, unknowns, bad fixed lengths, late ASCII/J errors, zero length,
all64-bit sequence boundaries, empty S, binary application bytes, source gaps,
continuous accepted-byte runs, held payload/completion, two live future H offers
through actual admission, and four reset cancellations with real fresh logins.
The oracle walks complete byte strings with built-in big integers and regex;
it shares no RAM indices, control FSM or decimal shift/add helper with RTL.

The source-only preparation has not run. No numerical vectors, HDL image, test
PASS, resource measurement, protocol certification or hardware result exists.

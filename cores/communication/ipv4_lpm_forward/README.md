# IPv4 longest-prefix header forwarding service

`ipv4_lpm_forward` owns a fixed20-byte IPv4 header, validates its checksum,
selects a runtime longest-prefix route, decrements TTL exactly once and rebuilds
the header checksum. It combines unchanged `ram_prefix_table` and
`acc_ipv4_hdr_csum`. This supplies actual network header behavior absent from
the generic prefix binding service. No payload RAM, external memory, software
lookup, downloaded route image or generated ROM is needed.

The caller retains the corresponding payload until this descriptor completes,
forwards only error0, and discards/errors all other outcomes. This is a bounded
header service, not a complete IP router: Ethernet, ARP/neighbor resolution,
MTU/fragmentation, local delivery, ICMP generation, multicast policy, options,
security policy and wall-clock residence-time accounting are outside it.

## Clock, ownership and configuration

One rising-edge clock, synchronous active-high public reset, no CE or CDC.
Reset gates every public ready/valid low and its rising edge cancels all owners,
clears the route table and requires canceled commands to be replayed. The old
checksum atom has an asynchronous low-active reset, explicitly driven by !rst;
the table and wrapper use synchronous high-active reset. There is no internal
clock crossing. The route table needs ROUTES clear clocks after reset; commands
may be captured meanwhile and wait for that clear to finish.

Every transfer is ordinary valid&&ready. Sources hold every field until accepted;
each held response stays stable. Configuration has priority over a simultaneous
packet offer. One owner includes all child operations and the complete held
response. No new owner is accepted on the prior response's retirement edge;
the earliest acceptance is the following edge. There is no timeout on stalls.

ROUTES is1..128(default32), TAG_W1..32(default8). CW=clog2(ROUTES+1), at least1,
is derived and must not be overridden. Unsupported public parameters elaborate
a named missing-module guard. Every key, address, count and port is unsigned;
there is no fixed-point arithmetic or rounding.

Configuration is the original prefix table protocol with40-bit values packed
as `{port[7:0],next_hop[31:0]}`:

| c_op | Operation |
|---|---|
|0|LOOKUP c_prefix; length/value ignored|
|1|PUT c_prefix/c_length and port/next_hop|
|2|DELETE exact c_prefix/c_length; value ignored|
|3|CLEAR; all key/value fields ignored|

Lengths use the full32-bit input; values>32 return status3 before narrowing.
Host bits are ignored for PUT/DELETE. /0 and /32 are legal distinct identities;
the canonical containing prefix with greatest length wins. PUT replaces an
existing identity even while full. No eviction or multipath selection occurs.

`c_rsp_valid/c_rsp_ready` returns status0OK/1NOT_FOUND/2FULL/3BAD_LENGTH,
found/inserted, old canonical prefix/length/value, post-command count and tag.
Old fields describe the prior binding when found; otherwise they are zero.
CLEAR returns all old fields zero and count0. Mutation commits before response
presentation. A held admin response fences all packet and admin traffic.
For packet routing only, stored next_hop0 means an on-link route: m_next_hop
becomes the packet's destination. Admin lookup still returns the stored zero.
Port0 is legal. The caller supplies downstream egress/neighbor handling.

## Header input and result

`p_header[159:152]` is the first on-wire byte, byte8 is TTL, bytes10/11 checksum,
bytes12..15 source, bytes16..19 destination. `p_bytes` is the available IP
datagram byte count, excluding Ethernet padding/header/FCS as decided upstream;
it must include at least total_length bytes. This descriptor is trusted to
describe the actual retained payload. Extra trailing bytes are permitted.
`p_tag` is opaque and returned on every result.

Validation order is format, checksum, TTL, then route. Format requires version4,
IHL5, p_bytes>=20, total_length20..p_bytes, reserved flag0, and no DF together
with MF or nonzero fragment offset. Fragmented headers with DF0 are routable;
there is no payload assembly or fragmentation. Checksum verification includes
the transmitted checksum and requires the ten network-order words to fold to
ffff. Both zero encodings accepted by that fold are legal. TTL0/1 cannot forward.

| m_error | Result |
|---|---|
|0|Forwardable header and longest matching route|
|1|Unsupported/malformed header or available-length mismatch|
|2|Bad received checksum|
|3|TTL exhausted at this hop|
|4|No containing route|
|5|Unexpected child response or injected/internal helper fault|

Every packet owner returns exactly one held result. On error, m_header is the
accepted original header and next_hop/port/prefix/length are zero. m_count is
the route occupancy snapshot, and m_tag is preserved. On success, only TTL
and checksum bytes change; m_prefix/m_prefix_length identify the selected
canonical route and m_next_hop/m_port select the caller's egress path. m_count
is not a route identifier. No speculative header is published before success.

The checksum is fully recomputed with the new TTL and checksum field zero,
not updated by unchecked ordinary integer addition. FIRST restarts each pass;
five two-word transactions fold after each pair. Thus partial sums cannot
activate the old checksum atom's18-bit overflow diagnostic in ordinary use.
A failed operation does not modify any route. A new owner always restarts the
checksum helper, including after an internal fault.

## Composition and current evidence

`example/ipv4_two_route_forwarder.sv` bootstraps an actual four-slot instance
after every reset: default /0 on-link port1, plus192.168.0.0/16 through
192.168.0.1 port2. initialized gates packet acceptance until both real PUT
responses complete. A boot error is sticky until reset. The example contains
the same real table and checksum modules, with no mocked route response.

files.f and example/files.f are relative to this package directory. Current
state is RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED until the explicit
finite source-reviewed checks have run. No synthesis/PnR/STA/board/PPA or old
regression is authorized. See ARCHITECTURE.md, SOURCES.md and the frozen plan.

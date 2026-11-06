# Bounded IPv4 fragment payload reassembly

One decoded IPv4 datagram context collects fragments in arbitrary order and
publishes the complete payload in byte order. A fragment can establish the
context at any offset; the last fragment establishes the total length. The
context key is source IP, destination IP, identification and protocol. This is
a bounded payload service; Ethernet, IP options, routing, transport checksum,
ICMP, automatic expiration and multiple simultaneous datagrams are outside it.
An owner must use FLUSH or reset to expire an incomplete context. No full IPv4
host compliance, packet rate or physical implementation is claimed.

`ipv4_header_reassembly` is an actual three-module composition: a packed,
network-order 20-byte header passes through the unchanged `acc_ipv4_hdr_csum`,
then the decoded core uses unchanged `cip_sync_sp_ram` for payload storage.
The header and fragment payload have separate handshakes. A packet front end
must discard a rejected descriptor's payload; it must not send that payload to
this core. This example is not a raw Ethernet/UDP parser.

## Ports and transfer ownership

One rising-edge clock, synchronous active-high reset, no CE/CDC. All transfers
use valid && ready. Sources hold all fields until acceptance; responses and
replay fields remain stable under backpressure. Reset immediately gates ready
and valid low; its edge cancels work and clears context/coverage, hiding stale
unreset RAM. It also ends pending source obligations. No timeout is inferred.

MAX_BYTES is every integer 1..4096 (default 512); TAG_W is 1..32 (default 8).
AW=max(1,clog2(MAX_BYTES)); CW=clog2(MAX_BYTES+1) are derived parameters and
must not be overridden. The example's CW is also derived. All input lengths
and offsets are unsigned, checked at full width before narrowing. DATA is U8,
addresses/counts are bytes, and offset8 is the IPv4 13-bit offset in units of 8.

Commands: c_op0 FRAGMENT, 1 FLUSH, 2 STATUS, 3 reserved. FLUSH closes the
context and clears coverage; STATUS observes it. Admin operations ignore all
descriptor fields except op/tag. Every accepted command returns one status
response, echoing tag. Exactly one owner persists through precheck, payload,
held status and all held replay bytes. A new command may remain offered while
busy, but cannot be accepted before that owner releases. Stalls are unbounded.

FRAGMENT length must be positive; offset*8+length <= MAX_BYTES and <=65515;
MF=1 length must be divisible by 8. This capacity contract assumes a 20-byte
header. A different key is rejected without evicting the active context.
Once a last fragment establishes total, no fragment may extend beyond it;
another last must end at the same position, and an MF fragment must end below
total. A new last cannot shorten below any already stored byte. Then every
covered block is scanned for overlap, including identical duplicates. The
entire overlapping descriptor is rejected before any payload handshake.

| d_status | Meaning, in check priority order |
| --- | --- |
| 0 | Success (including FLUSH/STATUS) |
| 1 | Reserved opcode |
| 2 | Length/alignment/capacity range |
| 3 | Foreign context key |
| 5 | Terminal-length conflict |
| 4 | Any overlap with committed fragment bytes |
| 6 | Payload LAST differs from the declared length |
| 8 | Example only: header/version/flags/TTL/checksum rejection |

Descriptor errors preserve the existing context. They consume zero payload
bytes. After successful precheck, exactly length bytes must be supplied, LAST
only on the last. An early LAST or missing expected LAST immediately aborts
the entire context and returns status6, zero active/filled/total. The sender
must abandon the remaining payload when LAST is rejected; the core does not
drain undeclared excess bytes. There is no partial object output.

d_active and d_filled describe the state after the operation, d_total is zero
until a terminal fragment is known. Filled is the number of unique committed
bytes. A successful completing fragment sets d_complete=1; its response still
reports active=1. After that status retires, replay has m_length total, m_src,
m_dst, m_id, m_protocol and the completing fragment's tag, increasing byte
order, LAST only on its final byte. The context remains owned until that byte
retires, then closes. FLUSH, descriptor errors and STATUS cannot replay data.

## Header example

h_header[159:152] is the first on-wire byte. h_op/tag replace c_op/tag.
Admin commands bypass checksum/header validation. FRAGMENT requires version4,
IHL5, total_length>=21, TTL>0, reserved flag0, and no DF with MF/nonzero offset.
All ten network-order words including the checksum must fold to ffff. The
unchanged checksum atom is driven by five sequential transactions with two
header words and two zero words each. FINAL folds after every pair, FIRST is
set on the first and VERIFY only on the last. The raw pair sum is <=196605,
below the atom's 18-bit carry diagnostic threshold even for all-ffff addresses. There
is no CE mismatch: clk_en is tied1 and reset polarity is explicitly inverted.
Malformed headers yield status8 and preserve the most recent context snapshot.
The example supports arbitrary protocol values; it does not verify UDP/TCP.

## Architecture and finite evidence

Payload RAM is MAX_BYTES*8 bits, 4096 default / 32768 maximum. Coverage is
ceil(MAX_BYTES/8) resettable bits, 64 /512. Starts are always 8-aligned; all
nonterminal lengths are multiples of8, and a terminal partial block can only
start at that same boundary. Therefore any overlapping coverage block implies
byte overlap. An exact filled-byte count and a checked terminal bound establish
complete coverage without scanning the payload or building a byte bitmap.
There is one RAM read/write port, no multiplication/division, vendor primitive,
external memory, duplicated payload or full-width address CAM.

Descriptor rejection is immediate except overlap, whose one-block-per-clock
scan takes ceil((offset*8+length)/8)-offset clocks. Successful precheck takes
the same scan, then payload accepts one byte per clock when continuously
offered. Completing LAST makes the status valid just after that edge. After
status retirement, the RAM request takes the next clock and first replay is
valid after it; always-ready replay retires one byte every2clocks. These are
source scheduling bounds, not hardware performance. Header validation uses
five request/result pairs before core issue. Qualitative resource risk is
MEDIUM; actual RAM inference, fit, timing, power and packet throughput UNKNOWN.

`FINITE_PLAN.json` fixes three syntax checks and four compile/sim pairs, each
child <=20s, fail-stop without automatic repair/rerun. Profiles are capacity1,
nonpower37, max4096 with short fragments/replays, and the actual header example
at80. Independent byte-dictionary vectors cover out-of-order fragments, holes,
all key fields, overlap, final conflicts, bad LAST, boundaries, flush/reset and
invalid headers. TB adds continuous input, held responses/replay, a real future
FLUSH, and resets during input/held completion/first/final replay/checksum.
Executable inputs, exact plan, independent vectors and raw logs are archived
before HDL children. Qualification is limited to the listed finite checks;
all versions remain HW_UNVERIFIED. Actual qualification is twelve PASS children,
one retained reference-vector FAIL and four successful simulations, including
a separately reviewed two-child example-only repair; no passed profile reran.
No synthesis/PnR/STA/board/PPA or inherited regression is run. See
QUALIFICATION.md and B39_DELIVERY.json for exact evidence.

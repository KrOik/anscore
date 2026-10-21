# Store-and-forward IPv4/UDP payload receiver

`rtl/udp_payload_rx.v` accepts an8-bit Ethernet frame stream without
preamble/FCS. Its upstream must qualify EthernetFCS (for example,
`rmii_frame_stream`); this module does not recalculate FCS. The integration
wrapper `rmii_udp_receiver.v` connects both layers with the same clock.

Supported packets: EthernetII IPv4, fixed20-byte IPv4 header, no fragments,
no VLAN, UDP to the configured local MAC/IP/port. Broadcast destination MAC
is accepted if the destination IP/port matches. IPv4 header checksum is
mandatory. UDP checksum0 is accepted under IPv4 rules; nonzero checksums
are verified over the pseudo-header and entire UDP datagram, including
zero padding for odd payload lengths. IP total length must exactly equal
20 plus UDP length, UDP length must be at least8, and the received frame
must contain the declared IP datagram. Ethernet trailing padding is ignored.
Maximum Ethernet input length1514bytes, maximum payload1472bytes.

The entire frame is buffered in a2048-byte synchronous memory. Validation
finishes before any payload is published, so corrupt packets never leak
partial data. Malformed metadata/keep, unsupported headers, checksum failures
or length mismatches are drained through input last and then rejected.
Only one frame is owned at a time. Input ready deasserts while checking and
delivering; the upstream must hold its data stable during that interval.
No continuous100Mbps throughput or routed timing is established.

Output valid/ready/data/keep/last:

- Nonempty payload: keep1 on every byte, last on its final byte.
- Empty UDP payload: one beat with data0, keep0,last1. It still counts as
  an accepted packet and must be acknowledged through output ready.
-96-bit user metadata is copied from input and remains constant; separate
  source IP/port outputs accompany every payload beat. All fields are held
  under output stalls. Reset discards input/output ownership and clears counters.

Counters increment once per complete frame, with mutually exclusive priority:
bad_header, bad_ip_checksum, bad_udp_checksum, or good. Good increments when
validation passes; output completion can follow later under backpressure.
Counters wrap32bits. Missing input last can hold the receiver indefinitely;
an owning replay/transport must supply a timeout/reset recovery policy.

Run after loading scripts/env.ps1:

```
python cores/communication/ethernet_udp/tools/test_udp_rx.py
```

Python independently builds IPv4/UDP packets and checks exact output bytes,
empty packet representation and boundaries. Seven good packets cover lengths
0,1,2,7,63,1472 plus33bytes with disabled UDP checksum. Seven rejected packets
cover IPv4/UDP checksum corruption, wrong destination port/MAC, fragmentation,
invalid UDP length and truncation. Seeded input gaps and output stalls are
included; the bench checks stable metadata and source address under stalls.
Source hashes, generated fixture, expectations and logs are archived.

`python cores/communication/ethernet_udp/tools/test_rmii_udp.py` exercises the actual
integration wrapper from50MHz RMII dibits through EthernetFCS to payload.
Seven good packets match Python byte-for-byte, with empty/odd/max payload,
random downstream stalls and source metadata checks. Eight failures include
six UDP/IP/header rejects and two receiver rejects (short Ethernet and bad
EthernetFCS). All layers drain before each independent fixture; this does
not establish sustained line-rate throughput or burst-loss capacity.

Still required for IP-07: generic UDP TX,
application sequence/CRC, control/counters/replay integration,25K P&R and
controlled-board evidence. Actual PHY validation remains conditional on
connected hardware; this digital simulation does not establish it.

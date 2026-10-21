# Buffered generic UDP frame transmitter

`rtl/udp_frame_tx.v` accepts one descriptor and payload, then emits an
EthernetII/IPv4/UDP frame including minimum-length Ethernet padding but
excluding preamble/SFD/FCS. It is a transport-neutral byte-stream packetizer;
it does not yet drive RMII or PHY pins.

Source MAC/IP are parameters. A descriptor latches destination MAC/IP,
source/destination ports, payload length0..1472,16-bit IP identification and
96-bit user metadata on command valid/ready. Configuration changes after
acceptance have no effect. Empty payload commands require no payload beat.
For nonempty payloads, keep must be1 and last must exactly match the declared
length. Data is buffered before publishing; invalid input produces no frame.

IPv4 is version4/IHL5, DSCP0, DF1/no fragmentation, TTL64, protocolUDP. Both
IPv4 and UDP checksums are generated. UDP checksum includes pseudo-header,
payload and zero padding for an odd length; complement0 is encodedffff.
The output has all keep bits1, last on the final frame byte, and stable data,
last/user under backpressure. Output frame length is max(60,42+payload_length).
Synchronous payload storage has2048 byte locations. There is one descriptor
and one owned frame, with at most one byte per3 clocks on output.

Completion remains asserted until done_ready. Error0 indicates all output
bytes were accepted; error1 rejects descriptor length>1472; error2 rejects
input keep or last/length mismatch. A malformed input without last is drained
through the next accepted last before returning the error. Missing last or
missing input data can therefore wait indefinitely: an owning control/replay
block must enforce timeout and reset/abort. Reset discards ownership and
output, including a partial frame. No automatic retry occurs.

```
. ./scripts/env.ps1
python cores/communication/ethernet_udp/tools/test_udp_tx.py
```

The test compares every frame byte against a Python encoder using network
byte order and one's-complement checksums. Six payload sizes0,1,2,7,63,1472
cover padding/odd/even/max size. Four error completions cover oversized
descriptor, early last, missing expected last with drain and invalid keep.
Seeded input gaps/output stalls, command latching and held completion are
tested. No EthernetFCS/RMII/physical throughput claim follows from this test.

Still required: frame-to-RMII serializer/FCS/IFG, integrated TX/RX replay,
application sequence/integrity counters, control and timeout recovery,
25K synthesis/P&R and controlled-board/optional physical-PHY acceptance.

# RMII transmit path

`rmii_frame_tx` buffers a complete Ethernet frame of60..1514bytes (excluding
FCS), then drives uninterrupted100Mbps RMII at a50MHz common clock. It emits
seven55 preamble bytes, D5 SFD, the frame, reflected IEEE Ethernet CRC32
complement in little-endian order, then at least48 idle dibit clocks (96bits).
Bytes are serialized low dibit first. No PHY-specific reset/MDIO or pin binding
is included. This is not a physical link validation.

Input is valid/ready/data/keep/last/user. Full-frame buffering means arbitrary
input gaps cannot create gaps on the wire. Metadata is constant per frame.
Short frames return error1; invalid keep/metadata or excessive length return
error2, draining through last if necessary. No malformed frame is transmitted.
Missing last requires an owning timeout/reset recovery mechanism. Global
reset can truncate an active wire frame and clears counters; receiving peers
must reject that frame. No automatic retransmission occurs.

Completion is held after FCS and IFG until acknowledgement. `sent_frames`
increments after the last FCS dibit; `sent_bytes` counts Ethernet bytes
excluding preamble/FCS. Counters wrap32bits. The next frame is accepted only
after completion ACK. No sustained line-rate application-throughput claim is
made for this single-buffer implementation.

`rmii_udp_transmitter` combines `udp_frame_tx` and `rmii_frame_tx`. Its result
waits for actual wire completion plus IFG, rather than reporting success when
the packetizer merely hands its last byte into a buffer. Error1/2 are the
packetizer errors; error4 indicates serializer rejection. Descriptor user is
latched for all completions, including failures before a frame is generated.

```
. ./scripts/env.ps1
python cores/communication/ethernet_udp/tools/test_rmii_tx.py
```

The actual integration wrapper is tested with six payload sizes0,1,2,7,63,1472,
input gaps, latched descriptors, held completion and four packetizer errors.
Python compares every captured RMII byte against an independent IPv4/UDP
encoder plus zlib EthernetCRC32, including preamble/SFD/FCS. The bench checks
whole dibit byte boundaries and at least48idle clocks between frames. These
tests exercise valid serializer input. `test_rmii_tx_errors.py` adds five
directed serializer rejects: short frame, oversized frame, invalid keep,
metadata change and drain-to-last after invalid keep. It checks held completion,
no wire output for rejects, reset during loading and clean recovery. Two normal
wire frames are compared byte-for-byte including independently computed FCS.
This still does not prove every possible reset instant or malformed sequence.

Integrated TX/RX replay, sequence/CRC, CSR/timeout recovery and25K P&R are
implemented and tested (SPEC.md, VALIDATION.md). Remaining acceptance includes
physical25K hard-JTAG/LA replay, license/release audit and actual PHY continuous
tests when hardware is connected.

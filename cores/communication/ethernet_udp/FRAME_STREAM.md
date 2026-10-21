# FCS-qualified RMII frame stream

`rtl/rmii_frame_stream.v` reuses unchanged canonical `av_rmii_rx.v`, exposing
whole Ethernet frames as an8-bit valid/ready/data/keep/last/user stream.
Preamble/SFD and four-byte FCS are excluded. Ethernet header and any minimum
frame padding are included. This layer does not parse or strip IPv4/UDP.

RMII dibits, CRS and stream logic use the same50MHz clock. No CDC is hidden
in this wrapper. The existing two2048-byte synchronous packet banks are held
until final output acceptance. A new frame is published only after the
canonical receiver's whole-frame FCS/length validation. Accepted wire frame
lengths are64..1518bytes including FCS; stream lengths are60..1514bytes.
Non-backpressurable RMII input is dropped and counted if both banks are busy.
There is no assumption that network senders honor application backpressure.

`keep=1` for every valid byte. `last=1` on exactly the final byte. All output
fields remain stable while valid and not ready. `user[31:0]` is the modulo32
delivered-frame sequence number, starting0 after reset. `user[95:32]` is the
free-running64-bit core-clock count when the bank is dequeued. It is constant
through a frame. This timestamp is **not** the first wire dibit arrival time;
bank queueing and downstream stalls can affect it. Reset discards all in-flight
frames and clears counters/timestamp epoch.

Counters: `rx_good` counts wire frames published to a bank; `rx_bad` counts
FCS/length rejects; `rx_overflow` counts receiver-dropped frames;
`delivered_frames` increments on accepted last; `delivered_bytes` increments
on each accepted byte. They wrap at32bits. Good and delivered counts can
differ while buffered data is pending. Delivery completes no faster than
one byte per3 clocks, with setup/release overhead per packet. No measured
continuous throughput or routed Fmax claim is made.

The canonical receiver does not expose RX_ER or PHY link status. Physical
adaptation must address those signals separately before claiming complete
PHY error handling. This wrapper adds no vendor I/O or pin assumptions.

Run `. ./scripts/env.ps1`, then:

```
python cores/communication/ethernet_udp/tools/test_frame_stream.py
```

The runner freezes sources and executes actual RMII dibit traffic. Python
independently checks2016ordered bytes and6packet boundaries for lengths
60,257,1514,60,61,64. The testbench checks seeded random output stalls,
held metadata, dequeue timestamps, receiver CRC rejection, blocked-bank
overflow and clean recovery. An initial compile failure from the reserved
SystemVerilog name `sequence` is retained in the artifacts; the register was
renamed `frame_seq`, with no expected numerical data changes.

Remaining IP-07 scope: generic UDP application receive/transmit contract,
checksum/error/sequence metrics, controlled replay/control-plane integration,
CDC when required,25K build and board evidence, optional actual PHY tests.
This Ethernet frame layer does not complete those requirements.

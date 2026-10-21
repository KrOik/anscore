# IP-07 canonical reuse baseline

Target work-order scope is a25K UDP stream subsystem with PHY adaptation,
buffering/backpressure, sequence/CRC/error counters, controlled replay and
physical100Mbps validation when a connected PHY is available. No25K
implementation or PHY result is established by this baseline.

Canonical sources under `projects/net_av_hdmi_20k/src/`:

- `av_rmii_rx.v`:50MHz dibit receive, two2048-byte banks, whole-frame FCS
  validation, pending/release bank interface, good/bad/overflow counters.
- `av_udp.v`:direct-link IPv4/UDP with NV01 media framing, ARP, session and
  sequence checks, credit admission, debug cumulative bytes/CRC and ACK TX.
  It is application-specific; it is not a generic application UDP TX stream.
- `av_async_fifo.v`:the legacy byte-stream CDC queue used by that protocol.
- `av_phy.v`:RTL8201 register sequence, dependent on SMI_ct and official
  example provenance; keep separate from a portable packet application.

`tools/test_baseline.py` freezes and executes the unchanged original testbench.
It checks7168delivered bytes, ARP/ACK EthernetFCS, IPv4 checksum rejection,
duplicate/future sequence rejection, credit exhaustion and successful retry,
asynchronous consumption, and debug cumulative CRC. It does not establish
general UDP payload checksums, arbitrary packet boundaries, arbitrary PHY
support, sustained100Mbps application throughput or25K board readiness.

Next required integration must preserve valid/ready and packet last/user
semantics under arbitrary downstream stalls, expose transport-neutral control
and counters, and provide independent golden traffic/error injection. Existing
NV01 behavior must remain explicitly named if retained. A25K PHY adapter
requires actual carrier/pin constraints; no PHY wiring is inferred from20K.
Distribution provenance/license remains part of IP-00 and is not granted by
the presence of these files.

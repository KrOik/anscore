# IP-07 Ethernet/UDP stream subsystem (development)

Target: Tang Primer25K, GW5A-LV25MG121NES. Current implementation is digital
RTL validated by simulation; no25K synthesis/P&R, SRAM controlled replay or
physical PHY result is established for this project.

## Current datapath

Transmit: descriptor plus8-bit payload -> `udp_frame_tx` buffered packetizer
-> `rmii_frame_tx` complete-frame serializer ->50MHz RMII dibits. Integration
wrapper: `rmii_udp_transmitter`.

Receive:50MHz RMII dibits -> unchanged canonical20K `av_rmii_rx` two-bank
FCS qualification -> `rmii_frame_stream` -> `udp_payload_rx` whole-frame
IPv4/UDP validation ->8-bit payload. Integration: `rmii_udp_receiver`.

The two sides use a common clock in current tests; no unsupported asynchronous
crossing is assumed. Application interfaces use valid/ready/data/keep/last/user
with stable outputs under stalls. UDP input payloads may be0..1472bytes.
Empty receive payload is keep0,last1; empty transmit descriptor needs no beat.
See UDP_RX.md, UDP_TX.md, FRAME_STREAM.md and RMII_TX.md for exact contracts.

Only EthernetII/IPv4 with fixed20-byte header and UDP is supported. VLAN,
IPv6, IP options/fragments and routing/ARP resolution are not implemented by
the generic path. Transmit supplies an explicit destination MAC. Both IPv4
and UDP checksums are generated; receive allows IPv4 UDP checksum0 but
validates nonzero values. EthernetFCS is generated/validated separately.

No application sequence prefix is silently added or stripped. The legacy
NV01 sequence/credit protocol remains a separately named canonical baseline,
not a substitute for the generic UDP application contract. Current receive
metadata contains a dequeue timestamp and delivered-frame index, not the
remote application's sequence or first-dibit wire timestamp.

## Verification

After `. ./scripts/env.ps1`, use `python cores/communication/ethernet_udp/tools/NAME.py`:

| NAME | Scope |
|---|---|
| test_baseline | Canonical20K NV01 ARP/credit/sequence/FCS regression |
| test_frame_stream | FCS-qualified Ethernet byte stream, banks/stalls/overflow |
| test_udp_rx | Independent encoder vs exact UDP payload/empty/boundary results and rejects |
| test_rmii_udp | Actual RMII->Ethernet->UDP receiver wrapper |
| test_udp_tx | Exact independent Ethernet/IP/UDP packetizer bytes |
| test_rmii_tx | Actual transmitter wrapper, preamble/FCS/IFG |
| test_rmii_tx_errors | Standalone serializer malformed frames, drain/reset/recovery |
| test_loopback | Actual transmitter RMII outputs wired to actual receiver |
| test_replay | Synthesizable finite owner, sequence/CRC, faults, timeout, reset/recovery |
| test_control | Canonical atomic config, real CSR replay, queued commands, counter/CRC readback |
| test_uart | Supplementary real bit-serial board-top control and replay |
| test_host | Actual CSR fixture, host verification and10 corruption/identity/timeout guards |

The full digital loopback checks seven good packets (payload0,1,2,7,63,1472,33),
1578 exact application bytes, metadata/source and timestamp order, random
receive stalls, four explicit malformed-input completions and subsequent
clean recovery. No test bypasses the EthernetFCS or IP/UDP checksum path.
Tests wait for drain between independent packets; this is not evidence of
sustained line-rate throughput or burst-loss capacity. Fixtures/source hashes
and logs are retained in artifacts/ethernet_udp_25k.

## Open requirements

- Extend controlled replay fault coverage and integrate its coherent result
  counters with board/runtime control (see REPLAY.md).
- Physical verification of the implemented atomic CSR/UART board binding
  and8-channel probe interface (see INTEGRATION.md); hard-user-JTAG backend.
- Isolated and full25K synthesis/P&R, actual Fmax/LUT/FF/BSRAM/DSP/IO metrics.
- Matching25K SRAM/hard-user-JTAG runtime read/write verification and LA capture.
- PHY adaptation for actual carrier, RX_ER/link/MDIO/reset and physical pinmap;
  actual100Mbps continuous test when a connected PHY is available.
- Dependency/license audit, integration example and complete release documents.

No PHY wiring is inferred from the attached20K. No physical download, analog
link or L3/L5 release claim follows from current simulation evidence.

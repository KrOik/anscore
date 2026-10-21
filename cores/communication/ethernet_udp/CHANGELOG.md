# Change log

## Development snapshot2026-10-21

- Audited unchanged20K NV01 RMII/ARP/sequence/credit baseline separately.
- Added FCS-qualified Ethernet frame stream and generic IPv4/UDP receiver
  with nonzero/zero UDP checksum handling and store-before-publish validation.
- Added buffered generic UDP packetizer and RMII preamble/FCS/IFG serializer.
- Added actual TX/RX wrappers, finite seedable sequence/CRC replay, timeout,
  fault injection, abort/reset recovery and held results.
- Added canonical atomic CSR configuration,8channel probes, supplementary25K
  UART binding and fingerprinted host numerical acceptance.
- Complete25K route/pack passes at50MHz constraint, achieved106.678MHz,
  final5278LUT4/2971DFF/5BSRAM. No image downloaded or physical link claimed.
- Added independent packet/CRC, malformed-frame, backpressure, serial-top,
  control/host corruption and recovery tests, retaining all earlier failures.
- Physical hard-user-JTAG/LA replay, external PHY when available, license
  resolution and release audit remain open.

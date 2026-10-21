# Changelog

## 0.1.0 — 2026-10-20

- Added explicit RGB888 SOF/EOL <-> line-packet conversion with frame-config
  latching, error flags and registered backpressure. Full-size frame pixel/
  metadata checks and codec-only II=1 test added; physical video gate is open.

- Added 72-bit CRC8 scan-to-CSR mailbox with held-data toggle CDC, common-reset
  abort/recovery, busy guards and coherent response snapshots. Three clock
  ratios pass 156 complete host-codec-checked transactions; end-to-end scan
  simulation loads/reads 290 words through the actual packet fabric. Device
  primitive binding, physical transport and CDC timing qualification remain open.

- Integrated host-loaded replay at CSR 0x40..0x64 through source 0 of the
  actual packet switch/width-conversion/FIFO path and a return repacker.
  Three datasets / 290 words pass independent full readback; original
  four-source CRC regressions remain covered. Added registered probe page 2.
- Generalized calibration for confirmed Primer 20K/CMSIS-DAP, including
  simultaneous LA capture plus JTAG IDCODE read; 20K evidence kept separate.

- Added guarded CSR wrapper around canonical host-loaded capture/replay RAM;
  three loaded datasets and error/reset/backpressure regressions pass.
  Isolated GW5A synthesis passes; board integration/hard-JTAG remain open.

- Added passive registered four-page logic_probe8 and physical pinmap linkage.
- Added 8/16/24/32 packet width adaptation using the existing byte serializer.
- Verified 16 width pairs, 128 packets per pair with independent byte golden,
  sparse keep, empty boundaries and random long backpressure.
- Default 32->24 synthesized for GW5A; integrated routing and board tests pending.
- Composed four-source arbitration -> 24-bit packing -> asynchronous packet FIFO.
  Three clock-ratio regressions passed 768 packets/22980 bytes total.
- Added composed FIFO overflow, exact-capacity, stalled reset and recovery tests.
- Added transport-neutral CSR endpoint and byte-strobe/error/backpressure tests.
- Added AXI-Lite bridge; verified 35 writes and 68 reads through real CSR with
  independently delayed AW/W, concurrent traffic and backend/response stalls.
- Added runtime four-source runner, CRC32, bounded timeout and 512x36 trace RAM.
- Integrated CSR start/config/status and guarded full trace readback; three
  cases pass without external reset, with independent Python zlib CRC checks.
- Added CRC8 UART transport, 25K board top, reproducible P&R/pack and D2XX runner.
  Physical synthesis/routing and SRAM download pass; UART ID read has no reply.

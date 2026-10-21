# Tang Primer 25K inverse-map board self-test

This isolated top checks `img_geo_inverse_map` with a fixed 4x4 perspective
matrix. It compares all 16 Q8.8 output coordinates, borders, errors, and frame
markers against a golden table. UART repeats `GEOMAP PASS` or `GEOMAP FAIL`
once per second after the startup delay.

Build from the repository root:

```powershell
. .\scripts\env.ps1
.\cores\system\common_scaffold\image\geometry\board_selftest\build_gw5a25.ps1
```

The build runs the Icarus testbench, GW5A-25 synthesis, 50 MHz place-and-route,
and packing. Keep the SRAM/JTAG `.fs` uncompressed: the pack command must omit
Gowin's `-c` option. Load it with `openFPGALoader -b tangprimer25k <image.fs>`;
the command uses volatile FPGA SRAM and does not write SPI flash. Read COM44 at
115200 8N1 and expect repeated `GEOMAP PASS` lines.

Board evidence from 2026-10-16:

- Simulation: **PASS**, `GEOMAP PASS`.
- GW5A-25 build: **PASS**, 651 LUT4, 395 DFF, 302 ALU, 0 BSRAM, 0 DSP;
  post-route Fmax 207.04 MHz.
- SRAM programming: **PASS**, JTAG IDCODE `0x1281b`, programmer exit 0.
- UART: **PASS**, COM44 returned repeated `GEOMAP PASS` lines.
- Uncompressed image SHA-256:
  `dd347b8689a231b2a016b0202445c4e06e3d73ed7f3d00fc53cb00c47dedd313`.
- Raw capture:
  [board_uart_uncompressed_20261016_020513.txt](build_gw5a25_20261016_015749_41868/board_uart_uncompressed_20261016_020513.txt).

The first build artifact was packed with `-c`, which made it unusable by
`openFPGALoader`; it is preserved beside the corrected uncompressed image.
This self-test covers only the specified inverse-map case, not the other
geometry functions.

# 25K board integration status — 2026-10-20

Latest: host-loaded integrated top routed/packed PASS in
board_20261020T154348294344Z: 3564 LUT4, 1442 FF, 10/56 BSRAM,
0 DSP, 11 IOB, 0 PLL. Fmax 93.24MHz, PASS requested 50MHz.
This new image has NOT been downloaded. Current connected hardware is Primer
20K/CMSIS-DAP ID 0x081B, SRAM reverse-signature calibration; see
artifacts/tang20k_la_calibration_20261020T153612484609Z.
Previous 25K-only observations below are historical. No NOR flash written.


Top: examples/25k/test_shell_top.v. Actual target GW5A-LV25MG121NES, E2 50MHz.
UART TX C3, RX B3; eight probes retain the physically verified pinmap.

Build: `artifacts/ip_test_shell_25k/board_20261020T145910258964Z` (repository relative).
Yosys and nextpnr pass. Physical usage: **2356 LUT4, 912 FF, 4/56 BSRAM**,
0 DSP. Reported routed Fmax 100.78MHz, PASS at requested 50MHz. No timing-ignore
option used. SDPX9B synthesis cell count is not physical BSRAM count; two cells
in the core occupy four physical blocks. Use routed reports for board PPA.

Initial pack failed because the script looked under lib instead of bin.
`--resume-pack` verifies unchanged source hashes and successful routing, and
packs without repeating P&R. Original failed summary/log remains;
summary_recovery.json records successful recovery and bitstream SHA256.

SRAM programming and independent JTAG GW5A-25 ID 0x1281b detection succeeded.
At that step FPGA SRAM ran this test shell; NOR flash was not written.
Windows D2XX found USB Debugger B serial 2025030317B. No COM port is required.
Actual UART ID command received **zero reply bytes**, so L3 functional and
same-image multi-case acceptance have NOT passed. Failure evidence:
`artifacts/ip_test_shell_25k/physical_20261020T150149746040Z/summary.json`.
Next: observe UART input/output pins to isolate the existing physical path issue.

Commands from repository root:

```powershell
. ./scripts/env.ps1
python cores/system/ip_test_shell/tools/test_components.py
python cores/system/ip_test_shell/tools/build_board.py
python cores/system/ip_test_shell/tools/build_board.py --resume-pack artifacts/ip_test_shell_25k/board_20261020T145910258964Z
python cores/system/ip_test_shell/tools/replay_runner.py --build artifacts/ip_test_shell_25k/board_20261020T145910258964Z --program
```

Component evidence `components_20261020T145800190326Z` includes CRC rejection,
partial-packet timeout, read/write/error response and TX-backpressure simulation.
These simulations do not establish that UART commands reach the actual B3 pin.

UART diagnostic follow-up: first valid 8CH capture decodes 95 actual TX=0x55
frames and D2XX receives the beacon, while RX has no edge. See LA_TESTPLAN.md.
The user confirmed wiring. After a stopped GPIO-mode driver hang, user-triggered
USB recovery restored JTAG and UART. Current SRAM is uart_diagnostic_top from
board_20261020T152034213074Z, not test_shell_top. No NOR flash written.
Current CH0..7 mapping G5,F5,G8,G7,H7,H8,J5,H5 passed bidirectional calibration.
Latest capture uart_la_20261020T152118136448Z is valid: 95 TX 0x55 frames,
RX high and no receive events during host transmission. Earlier all-high
captures used superseded probe constraints and are excluded. All logs preserved.

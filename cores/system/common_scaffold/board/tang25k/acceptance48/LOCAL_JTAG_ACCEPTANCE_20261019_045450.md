# Local JTAG acceptance repeat, 2026-10-19 04:54-05:15

48/48 original production entries passed three actual SRAM programming cycles and exact UART byte matches each (144 total).

Device: local Tang Primer 25K / GW5A-25; COM44, 115200 baud.

Evidence: [machine-readable run](restored_jtag_retest_20261019_045450.json), including individual board record links and post-run audit. All 202 production baseline files remain unchanged. No RTL fixes were needed. Newly generated temporary bitstreams were removed after successful tests; existing baseline artifacts were preserved.

Status: FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN. Scope: frozen bounded functional fixtures; hold timing, full-resolution performance and image-quality acceptance remain unproven. The separate extension library is excluded from these 48 board-tested entries.

Command: `python -B cores/system/common_scaffold/board/tang25k/acceptance48/retest_restored_jtag.py`

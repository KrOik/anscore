# Local JTAG acceptance repeat, 2026-10-19 03:43–04:03

48/48 original production entries passed. Each completed three actual SRAM programming cycles and exact UART byte matches (144 total).

Device: local Tang Primer 25K / GW5A-25, COM44 at 115200 baud.

Evidence: [machine-readable run](restored_jtag_retest_20261019_034310.json).

All 202 production source snapshot files were rechecked unchanged after the run. No RTL changes or new synthesis were needed. Frozen simulation, routed-netlist, resource and setup gates were checked before programming. Newly generated temporary bitstreams were removed. The 31 pre-existing selected bitstreams, existing evidence and baseline artifacts were preserved as required by AGENTS.md.

Status: FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN. Scope is bounded functional fixtures; hold timing, full-resolution operation and image-quality signoff remain unproven. New extension cores are excluded from these 48 entries and have not received board acceptance.

Command: `python -B cores/system/common_scaffold/board/tang25k/acceptance48/retest_restored_jtag.py`

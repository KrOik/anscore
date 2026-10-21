# Excluded from delivery by user instruction

The user explicitly stopped MPU6050 development and excluded it from delivery on 2026-10-19. This directory is retained as unfinished, unaccepted development material. Do not register this module, include it in delivery counts/manifests or initiate board programming/acceptance for it.

At the stop instruction, the two previously launched owner commands were collected to completion: test_transactions.py exited0 with38 simulation profiles PASS; synth.py exited0 with3 isolated synthesis profiles PASS (761/824/815 LUT,0 DSP,0 BRAM). No additional development, tests, synthesis or peer review was started after the stop instruction. The peer agent was notified to stop its pending work separately. These existing results do not constitute a delivery approval, physical IMU test, or board acceptance.

All existing RTL, Python, README, references, source freeze and logs/reports are preserved. The existing9-input source freeze predates this exclusion note; it describes that historical development snapshot, not an accepted delivery. No final acceptance report is created. This note intentionally does not modify that prior freeze or source-bound reports.

The controller covers a narrow MPU6050 raw transaction implementation and documented initial-state/DRDY/burst assumptions; it has no accepted DMP, attitude-fusion or analog-calibration implementation. Follow the exclusion decision over any earlier implemented status in the historical local manifest.

The owner processes are finished naturally (not forcibly terminated). TemporaryDirectory cleaned their generated HDL executables and workspaces. The closing read-only inventory found no owner binary/bytecode products and no remaining owner temporary directories. No existing source or validation artifact was deleted. No registered source, shared PHY, integration registry or board was changed.

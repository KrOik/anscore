# Isolated acceptance repairs

This directory contains separately frozen cases. Its name is historical;
some later cases also isolate harness changes for other public image entries.
No failed timing/resource build is a board PASS.

Dark channel merges two exclusive registered reads of RGB history into one
explicit read port. Transmission uses an exact 24-bit restoring divider.
Recovery shares an exact 23-bit magnitude divider over RGB, then restores the
sign and clamps to eight bits. Original independent integer oracles, original
golden UARTs and all seven normal/fault simulations are retained. All three
entries have three actual board runs in their respective successful cases.
Their exact repaired production sources are integrated, and the full original
dehaze regression passed at
`evidence/dehaze_adapters_20261018T150740Z_bb9989ad`.

`stage_harness.py` creates a new case; it never overwrites an old one. Registered
ROM outputs and precomputed count targets require the documented CE_DIV=4.
Clocked driver reset requires a running clock through POR. DUT reset contracts
remain unchanged. Every variant reruns all seven retained UART tests before
freezing source/expected/constraint hashes. Temporary simulation files are
automatically removed.

Frame-buffer RAM model now uses four persistent byte banks and unreset RAM
read registers. Its true byte enables, response holding and deliberate error
address remain covered by the original board vector set. Frame-buffer timing
is still failing; no frame-buffer board PASS is claimed.

All board passes are bounded functional evidence with hold timing unproven.
See the generated acceptance ledger for the current per-entry status and
pending differences between staged and production dependencies.

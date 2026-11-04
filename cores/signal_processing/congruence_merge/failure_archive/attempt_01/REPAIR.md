# Same-stimulus repair 01

Original plan SHA256
`d21778f725674aff06c2692635dfee8fd3dbaeaef02366d5b732d98026b66146`
was frozen before the first HDL child. Version, core syntax and example syntax
passed. The first W1 TB compile failed because `matches` is a SystemVerilog
keyword. No simulation ran and no timeout occurred. All 15 later children are
NOT_RUN in the original receipt. The exact 15 source/fixture files, original
plan, failure receipt and NOT_RUN suffix are preserved in
`failure_archive/attempt_00/` and verified against the original source hashes.

Repair changes only the complete TB identifier `matches` to `match_count` and
makes failure archival append to the next unused attempt directory. Production
RTL, wrapper, all six fixture byte streams, all expected values, profile sizes,
coverage targets, child order, hard 20-second limits and latency rules are
unchanged. No input or expectation is weakened. The new plan binds the current
sources and records the original plan/receipt hashes plus exact fixture hashes.

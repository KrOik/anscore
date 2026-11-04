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

# Same-stimulus expectation repair 02

Repair 01 passed W1, then W2 passed its 256 main fixture frames but failed at the
first fresh recovery. The unchanged actual input is `a=-1,b=1,m=2,n=3`.
Normalization gives `a mod 2=1` and `b mod 3=1`. Therefore the unique canonical
solution is 1 and least period is 6. The original expected solution 5 is wrong:
`5 mod 3=2`, which violates the original second congruence. RTL returned 1/6.
This is an independently demonstrated expectation error, not a changed domain.

The exact repair-01 files, plan and receipt, including 7 actual child records
and 12 NOT_RUN children, are preserved in `failure_archive/attempt_01/`.
No timeout occurred. Repair 02 changes only the even fresh-response expectation
5 to 1 in TB and its offline trace expectation. All actual source-driving
assignments (including the fresh transaction), all six fixture byte streams,
production RTL, wrapper, profile sizes, child order, bounds and 20-second limits
are unchanged. The odd fresh input also canonically produces 1/6, while W1
produces 0/1. No stimulus is dropped or altered.

`REPAIR02.diff` contains the complete unified diff of both affected code files
against attempt 01. Every source-driving assignment, target loop, 21-group
count and event wait is byte-identical. All 126 fresh expected rows (21 per
profile) were cross-checked by the primary GCD/inverse oracle before the next
HDL child; the W1..3 checks also enumerated candidate integers.

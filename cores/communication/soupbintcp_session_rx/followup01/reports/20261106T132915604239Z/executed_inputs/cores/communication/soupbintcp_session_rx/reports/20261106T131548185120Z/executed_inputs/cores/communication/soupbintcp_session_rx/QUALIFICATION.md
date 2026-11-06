# Qualification boundary

SOURCE ONLY: RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED.

No prepare_vectors.py, run_checks.py, model, HDL compiler, simulator, synthesis,
PnR, STA or hardware check has executed for this candidate. Planning only reads
source bytes, JSON, fixed tool metadata and hashes. No generated vectors exist.

Proposed finite gate: B45_SOUP_SESSION_RX_ONCE, one preparation plus nine HDL
children,3 simulations. Each child has20 seconds, process-tree termination5
seconds and one target completion wait2 seconds; first failure stops all later
launches, with no retry or cleanup. Successful binary images remain outside Git.
Any failed executed source/input becomes frozen and needs a separately reviewed
new attempt; this runner never edits or retries it.

The complete source/review/plan and all local dependencies are archived before
the preparation child. One independent oracle import creates all3 profiles;
their receipts and vectors are frozen before any HDL child. Raw streams, acquired
PIDs, exit/time/hash evidence precede result parsing. Exact counters, not just a
PASS substring, determine simulation success. Source/tool/vector/image hashes
are checked between children and at completion. Missing/changed inputs fail stop.

Passing that finite plan would establish only those simulations and syntax
checks, not all schedules, indefinite TCP reliability, arbitrary parameters,
exchange conformance, wire rate, Fmax, area, power, timing or hardware fitness.

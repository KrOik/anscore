# Independent payload testbench followup01

The original one-attempt receipt remains FAIL_STOP and all original source,
controls, prepared vectors/receipts, raw streams, initial/terminal/validated
records and compiled image stay unchanged. The first simulation returned rc1
before running the testbench because Icarus VPI rejects five direct fscanf
assignment targets with dynamic multidimensional memory indices.

This separately named core-TB copy reads those exact five fields into scalar
variables of the same widths, checks the same field count, then assigns the
same original array elements. No stimulus, golden value, expected counter,
reset/hold/ownership/credit check, RTL, wrapper, model or example TB changes.

A separately reviewed once-only gate permits zero preparations and exactly
four new compile/simulation pairs, reusing the original three vectors. The
actual fixed four-class example is included unchanged. The old failed image
is retained and is never executed again. Every child retains 20/5/sole2 limits,
PID/raw/terminal records, initial durable simulation image pin and no retry.
Failure stops and preserves this attempt. Root and worker_b source approval
of the exact new plan/seal/runner is required. Hardware remains HW_UNVERIFIED;
no synthesis, PnR, STA, board, PPA or historical regression is run.

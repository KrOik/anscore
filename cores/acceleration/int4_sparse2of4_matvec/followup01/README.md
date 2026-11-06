# Independent finite testbench followup

The original one-attempt plan remains FAIL_STOP. Its four preparations, three
syntax checks and tiny compile passed; tiny simulation returned rc1 at the
post-vector EOF assertion after ten numerical frames. Original controls, RTL,
TBs, prepared vectors, raw streams, child records and image are unchanged and
hash-bound by PREREQUISITES.json. No automatic retry is made.

Only these two separately named TB copies change: the final numeric scan,
which could return zero while consuming trailing whitespace at EOF, becomes a
string-token scan plus an explicit $feof check. An actual extra numeric or
nonnumeric token is still rejected. All scoring, directed tests, bounded waits,
reset/ownership/backpressure probes and expected counters remain unchanged.

This newly reviewed suite performs zero preparations. It reuses all four
original vector files, compiles four new images with these TB copies and runs
four deterministic simulations, each with 20/5/sole2 process bounds. The
original failed image is retained and never executed again. Requires a separate
root+worker_a source approval, exact plan/seal/runner hashes and unique once
guard. The unchanged core and actual Top-2 wrapper retain HW_UNVERIFIED status;
no synthesis, PnR, STA, board or PPA is performed.

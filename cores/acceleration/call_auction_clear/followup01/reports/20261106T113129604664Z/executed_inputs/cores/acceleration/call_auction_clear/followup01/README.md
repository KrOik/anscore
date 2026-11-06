# Independent book-parser followup

The original unique attempt is retained at
`reports/20261106T112045167982Z/results.json`: one preparation, three syntax
checks and three core compile/simulation pairs passed. The L1 actual-book
compile passed, but its simulation exited during VPI startup with
`$fscanf argument 3 (a vpiConstant) is not assignable` at the two-dimensional
array destination. No book vector case ran; the L8 pair was never launched.
The original failure, executed sources, guard, vectors, image and raw logs are
frozen. This followup does not change their outcome.

The separate testbench changes only the input destination: it declares one
signed 64-bit scalar, reads each decimal field into that scalar, checks the
same successful-conversion return code, then assigns the original array
element. Its DUT, expected results, scenarios, counts and checks are unchanged.
`LITERAL_STRUCTURE.json` independently records exact consumption of the two
existing files, 20 signed-64 fields per case and no trailing records. It uses
literal parsing, with no oracle or numerical preparation.

`PLAN.json` requests only the two book compile/simulation pairs, using archived
byte-identical copies of the original vectors and source closure. It performs
zero preparation, model import, syntax rerun or core regression. The original
three core successes remain separate evidence. Root and an independent peer
must review the full new sources and create `SOURCE_REVIEW.json` with the plan
hash and explicit gate `B44_CALL_AUCTION_FOLLOWUP01_ONCE` before the fixed
`Python312 -I -B run_followup.py --execute` entry may run. The new exclusive
guard is `.git/anscore-b44-call-auction-followup01-once.json`.

Every child has 20 seconds, a 5-second tree-termination interval and one final
2-second target-completion interval. STARTING and acquired PID are durable
before waiting; ordinary raw files are fsynced and exit/time saved before
parsing. The helper PID is durable before its bounded wait. Nonwaiting direct
target termination remains available after helper failure. An unconfirmed
target keeps its active PID and stops the suite. Failure retains all evidence
and launches no later child. There is no automatic retry, cleanup, staging,
commit, inherited execution, synthesis, PnR, STA, board or PPA work.

This source-only followup is unexecuted and remains RTL_CANDIDATE and
HW_UNVERIFIED until separate qualification evidence is written. Original
executed documentation and receipts are never rewritten to claim a pass.

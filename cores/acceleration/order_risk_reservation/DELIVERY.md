# B47 delivery

Qualification: LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.
The frozen README and followup README describe their pre-execution authoring
states; this additive document records the subsequent immutable receipts.

The capability is venue-confirmed lifecycle ownership around the existing
signed-position reservation ledger. Full 112-bit tokens retain pending-new,
live and pending-cancel state. A cancel request retains its hold, fills while
cancel-pending consume it, and venue-confirmed cancellation releases only the
unfilled quantity. Partial cancellation privately cancels and re-reserves the
smaller quantity under one owner. The actual example instantiates the existing
OUCH 4.2 server decoder and maps accepted, executed, canceled and rejected
events to the service. Unsupported or malformed venue events invalidate the
epoch conservatively.

## Retained initial attempt

`reports/20261106T153545298533Z/results.json` is FAIL_STOP, SHA256
`011d56278c7b527e7ecec455d64702851808acf59d174392f38c5cedc376838f`.
Three oracle preparations, three syntax checks and the first compile passed.
The first core simulation timed out; no simulation passed in this attempt and
later children were never launched. Target stdout and stderr are both empty.
The child has a 20-second target budget and total recorded time 20.875 seconds;
the tree helper exited successfully in 0.859 seconds and the sole target-exit
observation took 0 seconds. Target/helper exit and complete raw capture are
recorded, with no surviving child or helper. The timeout record has no
`execution_seconds` field; its original representation is retained.

Source review identified a reset/ready delta-cycle race in the original test
driver: it could miss an actual rising-edge command acceptance, then withhold
response-ready while waiting for command-ready. The example's local and byte
drivers used the same vulnerable polling rule. This is the paper diagnosis;
the original simulation produced no target diagnostic text.

## Independent followup01

`followup01/reports/20261106T154911716616Z/results.json` is PASS, SHA256
`f6f67a87d695f6690f29ac3482a966e81db1e571fa5dc5e7f9aef11082191829`.
It used a separately frozen plan and root/peer gate. All eight planned HDL
children passed: four compiles and four simulations. There were zero new
preparations; the three original vectors were reused by exact path and hash.

Only new testbench copies change the handshake drivers, add a settling edge
after reset release, and bound handshake/result/phase waits. They retain all
functional assertions, expected values, cases and reset scenarios. Original
RTL, example RTL, ledger/RAM/decoder dependencies, oracle, original testbenches,
controls, vectors, raw evidence and original images remain unchanged. This
followup neither reran nor replaced the failed attempt.

| Core contexts/orders/tag bits | Result checks | Held observations | Blocked observations | Reset counter | Canceled operations |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1/1/1 | 361 | 1444 | 1440 | 9 | 4 |
| 3/5/8 | 435 | 1740 | 1736 | 9 | 4 |
| 16/32/32 | 935 | 3740 | 3736 | 9 | 4 |

The actual decoder example passed 37 result checks, 148 held observations,
11 wire frames and a reset counter of 4. Core counters total 1731 checks,
6924 held observations, 6912 blocked observations, 27 resets and 12 canceled
operations. Reset counters include startup and scenario resets; they are not
counts of distinct test scenarios. All four simulations emitted their exact
PASS marker and `$finish`, with empty stderr. The largest followup child total
time was approximately 0.468 seconds. All eight children exited with complete
raw capture, no cleanup and no active child/helper. Compile warnings only note
missing explicit time unit/precision in synthesizable modules.

## Use and limits

Use `followup01/files.f` and `followup01/example/files.f` from the followup01
directory for the verified source closure and new testbench copies. Original
source lists and authoring controls are retained for traceability. Guards make
the recorded plans single-attempt evidence; they are not reusable test entry
points. Any further execution needs its own independent reviewed plan and
output paths.

Coverage is finite behavioral verification. Synthesis, placement and routing,
static timing, board testing and PPA measurement were not performed. Storage
and fit remain target-dependent and unmeasured. The service provides no price
or notional risk, replacement lifecycle, replay suppression, outbound order
encoding, session recovery or hardware-fault rollback. Applications must
reconcile venue state before clearing a faulted epoch.

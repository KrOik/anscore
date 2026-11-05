# Finite qualification

Production status: `LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED`.

The authoritative current execution is
`reports/20261105T164505364848Z/results.json`: 11 successful child commands,
with raw stdout/stderr retained. It binds production RTL, TB, runner and
example bytes via SHA-256 and confirms those files remained unchanged during
execution. Only executable sources and file lists are included in this source binding;
README, provenance and package metadata are not tested program inputs.

| Check | Scope | Actual result |
| --- | --- | --- |
| Icarus `-g2012 -Wall -tnull` | Default production top | PASS |
| Icarus `-g2012 -Wall -tnull` | ADDR_W=64, DATA_W=64, TIMEOUT_CYCLES=65536 | PASS |
| Icarus `-g2012 -Wall -tnull` | Default standalone example and RTL closure | PASS |
| Compile and deterministic vvp | ADDR_W=1, DATA_W=8, TIMEOUT_CYCLES=1 | PASS |
| Compile and deterministic vvp | ADDR_W=7, DATA_W=24, TIMEOUT_CYCLES=8 | PASS |
| Compile and deterministic vvp | ADDR_W=16, DATA_W=32, TIMEOUT_CYCLES=8 | PASS |
| Compile and deterministic vvp | ADDR_W=64, DATA_W=64, TIMEOUT_CYCLES=8 | PASS |

There are four successful limited simulations; this is not exhaustive
parameter or protocol verification. The TIMEOUT=1 configuration exercises
timeout/quarantine/reset paths; the three TIMEOUT=8 configurations additionally
exercise normal concurrent reads/writes, both AW/W arrival orders, all response
codes, forwarding of protection/strobe/data/address fields, final-edge response
priority and recovery after reset. Tests independently specify expected
forwarding and errors, assert exact timeout counts, hold response outputs
under stalls, and check preservation of stalled downstream request payloads.
Both unaccepted requests and accepted requests with missing replies are timed
out; their late replies must not produce duplicate upstream responses.
Read and write fault independence is tested in both directions. Reset covers
in-flight ownership and sticky faults.

All four TB compilations report only Icarus's missing-explicit-time-unit
warning for the production module. Production RTL contains no delay, so this
does not change its functional clock-edge behavior; raw warnings are retained.
No functional/compiler failures occurred. The first recorded execution
`reports/20261105T164128535372Z` passed a smaller version of the TB; the later
execution added meaningful timeout/late-response checks without changing RTL.
The intermediate execution `reports/20261105T164245619590Z` passed the
current TB. The latest execution additionally checks the then-current runner, whose
dependency/timeout stop behavior was tightened. Historical successful records
remain intact and are not counted again as current coverage.

After that evidence was recorded, a runner-only cleanup edit catches failures
or further timeouts from `taskkill` and final `communicate`, preserves captured
raw bytes and the primary TIMEOUT status, and attempts direct kill when needed.
The edit was source-reviewed; its execution/cleanup paths are **NOT_RUN**.
RTL, TB, example and both file lists are unchanged. Of the six executable/file-list
inputs in the latest receipt, only `run_tests.py` now differs. The exact executed
runner is retained as `history/run_tests.executed.py.txt`, whose SHA-256 matches
the receipt's `run_tests.py` entry. Current snapshot metadata binds the edited
runner separately; this source edit does not create additional HDL evidence.

Source review found one writer per sequential register, complete continuous
combinational assignments, bounded timer state, no dynamic arrays or
simulation-only production constructs, and explicit ownership between
upstream responses and downstream drains. No changes to any existing IP were
needed. Shared reset with the protected slave is a required integration
condition. No broader FPGA validation is claimed.

Synthesis, placement/routing, STA, board execution, formal verification,
CDC analysis, actual resource measurements, throughput measurement and full
regression: **NOT_RUN**. Hardware maturity remains **HW_UNVERIFIED**.

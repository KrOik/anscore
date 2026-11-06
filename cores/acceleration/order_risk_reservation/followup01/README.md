# Independent handshake-driver followup01

The original attempt is frozen FAIL_STOP at
`../reports/20261106T153545298533Z/results.json`, SHA256
`011d56278c7b527e7ecec455d64702851808acf59d174392f38c5cedc376838f`.
Three oracle preparations, three syntax children and the first compile passed.
The first core simulation timed out with empty target raw output. The bounded
tree helper exited after0.859s, the sole target observation took0s; both target
and helper were confirmed exited with complete raw capture and no survivor.
There is no automatic retry or modification of the original evidence.

Paper root cause: reset_now released rst_n at a falling edge and returned
immediately, before the continuously assigned ready signal settled. accept
could observe old ready0, then wait for a rising edge and a falling edge before
checking ready again. The DUT accepted the first GET_CONTEXT at that rising
edge and entered ownership, so ready was0 again at the check. The TB missed
the actual transfer and waited forever while withholding result-ready; the
DUT correctly held NOT_CONFIGURED. The example's local driver has the same
failure mode. Its byte driver is corrected by the same transfer rule.

Only new TB copies change: drivers hold valid/payload until an actual rising
edge with ready, reset release gets a settling edge, and every handshake,
response and phase wait has a bounded cycle counter with case/reset/core/
ledger context. Core wait bounds are16*ORDERS+128 clocks, example bounds1024.
Global watchdogs are reduced to10ms core and2ms example; these are secondary
simulation guards, not higher process budgets. All assertions, numerical
expectations, cases, four core reset probes and two example reset scenarios
are preserved. RTL, protocol example RTL, dependencies, oracle and all original
TB/helper/plan/control/vector/raw/image bytes are untouched.

The independent plan executes zero preparations and exactly eight HDL children:
compile/sim for all three original core profiles and the actual OUCH example.
The three already prepared immutable vectors are reused by exact path/hash;
there is no oracle import or numerical regeneration. Explicit new source lists
resolve from this followup directory and reference the original frozen RTL.
All old source/archive/control/terminal/raw/vector/image prerequisites are bound
before execution and after each child. Each child still has20s target,5s tree
termination and sole2s target exit observation; any failure stops later children.

Pre-execution status: SOURCE_ONLY / NOT_RUN. Execution requires a separately
pinned root+peer review and the independent followup01 once gate. No old
helper/model/HDL or new helper/model/HDL is run during source authoring.

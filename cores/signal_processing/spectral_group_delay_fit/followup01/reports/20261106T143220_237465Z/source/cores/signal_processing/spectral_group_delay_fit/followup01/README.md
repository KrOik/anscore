# Independent followup01

The original attempt is frozen FAIL_STOP at
`reports/20261106T142519_554598Z/results.json`: five preparations passed,
both syntax checks passed, the first compile passed, then the first simulation
stopped at time30000 before any DUT stimulus because reset_now lowered rst and
immediately checked combinational c_ready in the same simulation delta.
The old masked ready was still low. The RTL and numeric contract have not changed.

This directory contains one new TB copy. Its only byte-level source change is
`rst=0;` to `rst=0;#1;` at reset_now deassertion, allowing combinational signals
to settle before checking them. The original TB/source, controls, five vector
files, preparation receipts, compiled image, all9 child records and18 raw
streams remain immutable. PREREQUISITES hashes live and archived source and all
original evidence before a new lock, before every child and at completion.

New independent source/plan/seal/guard/root+peer gate authorizes exactly ten
HDL children: compile/sim for the same five profiles. There are zero model or
preparation executions, zero syntax reruns, no old helper execution and no
automatic retry. All original inputs and expected counters are reused from
their exact original paths. Compilation reads frozen old RTL/source lists;
only the new TB is taken from the followup archive.

The new runner retains20s child,5s tree helper and sole shared2s exit/drain,
durable PID/exit/raw evidence before parsing, explicit TIMEOUT and fail-stop.
This followup is SOURCE_ONLY / NOT_RUN until its own exact gate. Physical
implementation remains HW_UNVERIFIED.

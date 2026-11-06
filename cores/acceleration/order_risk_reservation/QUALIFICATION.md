# Qualification record

Current status: LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE /
HW_UNVERIFIED. See `QUALIFICATION.json` for exact receipt/control hashes and
literal counters, and `DELIVERY.md` for the capability and boundaries.

Two independent attempts are retained. The initial attempt stopped at its
first core simulation TIMEOUT after three successful preparations, three
syntax checks and one compile. It has zero successful simulations and empty
target raw streams. Tree termination and the sole target-exit observation
closed without survivors. Its report, sources, controls, vectors, compiled
image and raw evidence remain unchanged.

Followup01 passed its exact eight-child plan: four compiles and four
simulations, with zero new preparations and exact reuse of the three original
vectors. New testbench copies repair the missed-handshake polling and add
settling/bounded waits; RTL and numerical expectations are unchanged. Core
profiles 1/1/1, 3/5/8 and 16/32/32 passed 361, 435 and 935 result checks. The
actual OUCH decoder example passed 37 result checks over 11 wire frames.
Successful simulation raw output contains exact counters and `$finish`; all
simulation stderr is empty. Compilation warnings concern module time units
and precision only.

These receipts qualify finite unit behavior and the actual example closure.
They do not qualify hardware area, frequency, power, timing closure or board
operation. No synthesis, PnR, STA, board or PPA work was performed.

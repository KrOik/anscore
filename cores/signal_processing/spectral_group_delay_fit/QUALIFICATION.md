# Qualification and limits

PASS comes from the independent followup01 receipt, with the original preparation
and syntax evidence retained separately. The original attempt remains FAIL_STOP;
its TB reset-delta failure is not relabeled as a numerical RTL failure or a pass.
The sole new TB difference and every original frozen prerequisite are recorded
in followup01/PREREQUISITES.json and its source seal.

| Profile | Main cases | Main holds | Reset/recovery | Future outputs/holds | Exact last-input tail |
| --- | ---: | ---: | ---: | ---: | ---: |
| Core P8/MAX5/TAG1 |39|156|7/7|2/8|445|
| Core P16/MAX64/TAG8 |39|156|7/7|2/8|838|
| Core P24/MAX256/TAG32 |39|156|7/7|2/8|1154|
| Actual I/Q P8/MAX5/TAG1/ITER8 |25|100|8/8|2/8|455|
| Actual I/Q P16/MAX64/TAG8/ITER24 |25|100|8/8|2/8|864|

Every recovery result has4 held cycles. Main results compare all mathematical
outputs and command/count/tag metadata against the independent pairwise integer
oracle. Tests include negative-half-turn ties in both modular directions,
signed initial phases, multiple wraps, N2 zero residual, nonlinear residual,
both delay signs, first-bin invariance, P24/N256 negative unfolding to -2^31,
final RNE ties with both signs/parities, full32bit illegal config, early/missing
LAST, invalid phase priority, zero I/Q and fresh recovery.

Each live reset target is observed in the real arithmetic/ownership state before
cancellation. A future command remains offered through active computation and
held output; the retirement edge blocks it and a later actual handshake is
scored. Each sample driver also obeys real source backpressure. I/Q comparison
uses exact axes/diagonals through the actual unchanged CORDIC; general-angle
accuracy and arbitrary physical phase continuity are outside this check.

Original5 preparation children and4 HDL children, followed by0 preparation and
10 HDL children in followup01, give19 total process records and38 raw streams
across the B episode. There were no retries of either sealed plan, hidden oracle
calls, inherited regressions, synthesis, PnR, STA, SDF, board or PPA execution.
The1.812s longest followup simulation is host execution time and is not hardware
throughput. Measured HDL tail cycles support the stated transaction schedule;
full command budgets in README remain an analytical always-ready schedule.

The original incomplete receipt's input flag stays false. Its20 current sources,
20 archived sources,6 current/archived controls, lock/receipt,10 vector/receipt
files,9 child records,18 raw streams and1 image (86files) have independent exact
SHA256 and byte checks, together with24 tool hashes. The followup rechecks these
before each child and at completion, and its own input-stability flag is true.

No target device, clock constraint, physical resource total, Fmax, sustained FFT
service rate, power or board behavior is qualified. Logical register/operation
budgets are architecture estimates. Caller-owned FFT/frequency grid and phase
identifiability constraints in README remain required.

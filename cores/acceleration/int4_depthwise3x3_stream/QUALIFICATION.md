# B44 finite qualification

LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.

Default, maximum and RGB-example syntax passed. Five independent full-image
preparations produced frozen expectations. Five compile/simulation pairs using
the separately reviewed followup TB passed: C1/3x3/T1, C3/7x5/T8,
C16/3x3/T32, C1/1024x3/T8 and actual RGB3/5x4/T8.

Each simulation completed6 numerical frames,4 live cancellation/reset probes,
24 held-future-command cycles followed by actual acceptance, and actual reset
recovery. Exact output data, clipping, inexact, channel/coordinates, markers,
tags and completion counts matched. The tests include mixed signed kernels,
positive/negative nearest-even half ties, signed32 bias/U16 scale extremes,
zero scale, changing runtime geometry/channel stride and stalled interfaces.

The initial tiny simulation failed after numerical-frame processing at the
TB's terminal `$fscanf` EOF-return-code assertion. Literal structural parsing
proved all5 vector files consumed exactly with no trailing record. The new TB
rejects any actual next `%s` token, permitting either no-token return code.
Its only difference is that assertion. The original failed source, plan, gate,
logs, receipt and image remain unchanged. No oracle/preparation or syntax check
was repeated in the separately gated10-child followup.

Total evidence is15 HDL children:14 PASS +1 retained FAIL, with5 successful
simulations and5 successful numerical preparations. Six original images stay
local outside Git. EVIDENCE_AUDIT.json binds receipts and image hashes.

These are finite checks, including all supported channel-count extremes and
maximum-width row streaming; they do not exhaust the maximum all-axis image or
inject internal faults. No synthesis, PnR, STA, board, PPA, inherited regression
or whole-network inference was performed. Unchanged dependency history does
not qualify the new composition as hardware verified.

# B46 delivery

The new phase-band OLS group-delay core and actual I/Q composition are delivered
with exact B/C/D/residual outputs, signed sample-Q16 delay and original repository
operator reuse. RTL, old dependencies and numerical oracle were not changed after
the first attempt. Physical status remains HW_UNVERIFIED.

The original attempt is preserved FAIL_STOP:
`reports/20261106T142519_554598Z/results.json`. It completed5 oracle preparations,
2 syntax checks and the first compile, then stopped at time30000 in the original
TB's reset-deassert delta check. Its `inputs_unchanged=false` field is preserved;
the followup independently proves exact original source/evidence hash and byte
identity, rather than rewriting that incomplete-run flag.

The separately reviewed followup01 changes only a new TB copy, adding `#1` after
reset_now lowers rst. It reuses all5 original vector sets and preparation
receipts, performs0 preparations and exactly5 compile/sim pairs, and passes:

`followup01/reports/20261106T143220_237465Z/results.json`

Receipt SHA256:
`a6ab223b00a58ae85bbd341d3bd0c2697ae106f6b25800ffd396f93ef971bd7c`.
`suite_complete`, `inputs_unchanged`, `exact_plan_executed` are true;
active_child/active_helper are null. All10 children returned0 with complete
capture, no timeout, cleanup helper or automatic retry. All original86 files
and24 tools retain exact guard identity through the followup.

Across the passing5 profiles,167 main cases,37 recovery results and10 future
command results are scored (214 results total), with856 held-result cycles.
37 live cancellation fixtures cover partial input, sample/final multiplication,
division, held output and actual atan. Default core/actual tail latency from
last accepted input is838/864 cycles. See QUALIFICATION for profile scope.

Original README/STATUS/source/plan/seal/review, all preparation/vector bytes,
both attempts' process records, archived source and raw streams are frozen.
These new delivery notes record the final state without editing executed input.

# Independent post-run peer audit

Evidence audit: **PASS_FAIL_STOP_EVIDENCE**. Original design run: **FAIL_STOP**, reviewer worker_c,2026-11-06.

Original results SHA256: 011d56278c7b527e7ecec455d64702851808acf59d174392f38c5cedc376838f.

- Exactly8 children launched from the14-child plan:3 preparations PASS,3 syntax PASS,1 tiny compile PASS and1 tiny simulation TIMEOUT. The6 later compile/simulation children have no launch record, raw output or image. No simulation succeeded.
- All17 canonical and archived sources,25 case-distinct tool path entries (24 unique Windows files),3 canonical/archived controls,8 child receipts,18 raw streams,3 vectors and1 VVP image match original pins. The attribute file archive uses its documented .executed.txt name.
- Preparation records are361/435/935, and vector headers/row counts/hashes agree. All3 oracle PASS markers are present; first tiny simulation stdout/stderr are empty with no false PASS marker.
- The sole simulation launch prechecked and durably recorded the same VVP SHA256 as compilation: f08832fa7368fdd729bf09e86097de94fe6d35a3a63cf3a87bc71e539ac40516.
- Target PID45808 reached the20s execution deadline. taskkill helper PID50640 exited0 after0.859s, within its5s budget, terminating target45808 and descendant49424. Sole target observation took0s. Gross record duration20.875s includes termination. Target/helper exits and both raw captures are confirmed.
- Current OS metadata finds target45808, descendant49424, helper50640 and original parent50132 absent. Report active child/helper fields are null and active_helpers is empty. No later child launch or retry occurred.
- Reviewed runner source uses20s execution,5s tree termination and one2s target observation; direct file capture requires no pipe-drain waits. Failure reaches the first status assertion and stops the plan.
- FAIL_STOP, suite_complete=false and exact_plan_executed=false are retained honestly. inputs_unchanged=true and archive_complete=true independently match the byte audit. Original controls, sources, failed VVP/raw output and results remain unchanged.
- Compile warnings only concern absent explicit time units. This evidence audit does not diagnose the empty-output timeout or claim functional/physical qualification. No project code was imported, parsed as AST, executed or rerun.

Evidence discrepancies: 0. Separate follow-up work requires its own reviewed sources and gate.

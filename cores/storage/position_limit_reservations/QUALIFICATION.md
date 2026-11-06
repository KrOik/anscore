# B42 position_limit_reservations qualification

Status: **PASS_WITH_RETAINED_TESTBENCH_FAILURE**. Maturity: LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED. Baseline: `2e7a6fb51f32e525c1026c28d1f2f45e36545ebc`.

The original finite execution completed 11 HDL children: 10 PASS, 1 FAIL, with all three core simulations successful. Its example failure was an invalid testbench scenario: position1 minus outstanding sell5 and requested sell2 gives -6, below minimum-5. RTL correctly rejected the reservation. The reviewed repair changes only the request quantity and expected remainder from2 to1, preserving all RTL, oracle code, other stimulus, and assertions. The two-child repair (example compile and simulation) passed. Cumulative evidence is **12 PASS / 1 retained FAIL / 13 HDL children / 4 completed successful simulations**, with three archived oracle preparations, zero planning or repair oracle calls, and no automatic retry.

The failure raw timestamp `5375000` uses 1ps precision and means **5375ns**. The frozen REPAIR01.md unit error is preserved; this qualification supplies the correction.

| Core A/K/T | Commands | Holds | Preoffers | Future queries | Resets | Cycles |
|---|---:|---:|---:|---:|---:|---:|
| 1/1/1 | 511 | 3066 | 505 | 218 | 6 | 5870 |
| 3/5/8 | 525 | 3150 | 519 | 222 | 6 | 6760 |
| 16/64/32 | 682 | 4092 | 676 | 211 | 6 | 23251 |

The real IOC example completed21 offered orders,19 done results,8 fills,17 admin and8 maintenance operations,183 held-output cycles,22 blocked offers,4 resets,2 cancelled operations, and2 isolated results (1779 cycles). The wrapper reserves the whole requested IOC quantity, forwards real matcher fills under backpressure, then settles fills and cancels residual quantity before publishing done. Positions persist across orders.

Independent metadata audit verified17 original archived inputs,20 current/repaired archived inputs,52 protected parent artifacts,26 raw streams,3 structurally recounted vectors,13 exact process records with20s/5s/2s hard/tree-kill/drain budgets, both tool binaries, and all5 retained images. The only original/current source exception is the corrected example testbench. Both executed plans differ from their reviewed pending versions only in the source-review status. All failure artifacts remain intact.

Only missing RTL timeunit/timeprecision compilation diagnostics were observed; raw diagnostics are retained. No synthesis, placement/routing, static timing, board validation, PPA, or inherited regression was performed. Serial ticket scans, finite simulation coverage, and sticky isolation without rollback remain the stated limitations. See QUALIFICATION.json, EVIDENCE_AUDIT.json, FAILURE_AUDIT.json, and B42_DELIVERY.json for exact hashes and mappings.

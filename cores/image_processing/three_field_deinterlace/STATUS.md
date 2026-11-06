# Qualification status

LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.

Receipt: `reports/20261106T034957790812Z/results.json`, SHA256
`06ca26d331888408bc1b6cef901851a9fd0029c84e8f5ff9eb1f19926c5bd3ad`.
Twelve first-attempt finite checks passed; five simulations completed and checked
28,224 output records, 15 marker aborts/recoveries and 20 reset events. Six
executable sources, their archived copies, all 15 generated vectors, the plan
and all 24 raw stdout/stderr files were subsequently hash-verified. No retries.

Actual no-stall timing: first output acceptance 10 enabled edges after final
capture; W outputs at II=1 with six empty edges between rows; final acceptance /
held DONE after `H*(W+6)+3` enabled edges. These are RTL and simulation cycle
facts, not an FPGA frequency or continuous-input throughput measurement.

No synthesis, PnR, STA, board, frequency or resource measurement was performed.
Maximum geometry / invalid-parameter elaborations were not tested. Maximum
logical storage is HIGH risk (1,179,648 bits) and is not a device-fit claim.

# B41 retained-trade statistics qualification

Three core profiles N1/T1, N7/T8 and N64/T32 passed on the original reviewed execution. The original actual-example simulation failed because the wrapper discarded the failed ADD response's retained-entry count before isolation. All original10 PASS/1 FAIL checks, raw streams, exact sources, saved vectors and four images remain retained.

The independently reviewed repair changed exactly one wrapper branch to capture the original failed child result before invalidating both children. Core RTL, oracle, both TBs, original runner, original plan and all other original inputs stayed unchanged. A separate fixed2-child example compile/sim plan passed once. No oracle or successful core/syntax profile was rerun. Total:12 PASS,1 retained FAIL,4 successful simulations across13 HDL children.

Core totals:1,782 checked responses,891 actually admitted future QUERYs,10,701 held clocks and27 resets, plus15 deliberately cancelled commands. The actual ITCH example completed84 checked results from89 accepted commands (five cancelled by reset),42 actual future QUERYs,507 held clocks,252 blocked clocks,21 actual event results,12 trade additions and3 isolation acknowledgements, with6 resets.

An independent standard-library audit checked18 current/archive inputs,16 original archived inputs with exactly the wrapper current exception,26 raw streams,3 saved vectors by record counting,2 tools, both plan review-field changes,13 exact argv/cwd/limits records and all five compiled images. No checker/model was imported and no HDL was executed by this audit. All three mature dependencies match baseline raw Git bytes. See QUALIFICATION.json, EVIDENCE_AUDIT.json and FAILURE_AUDIT.json for exact mappings/hashes.

Compile diagnostics only identify modules without explicit timeunit/timeprecision. No synthesis, PnR, STA, board, PPA or inherited regression was run. Maturity: LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.

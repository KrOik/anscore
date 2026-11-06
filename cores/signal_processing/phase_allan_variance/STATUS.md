# B41 phase_allan_variance qualification

Current status: LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.
Icarus syntax and the exact finite unit suite passed once after independent root
source/plan review. These statuses do not imply mapped or hardware qualification.

- Baseline:31a83135a22f845d85840524986895217567625c.
- Original frozen plan:18ff7e027c9f66a90d1ebcbc164940a4bf211fd16a6e80369213cd10090b20d0.
- Original frozen seal:03d4a6c05b4355e4288eb72545c0dea96b613181f1c911d37acbfcc9a217c9e5.
- Receipt:reports/20261106T073240_936465Z/results.json.
- Receipt SHA256:86f1364303e523446a083b6e9c0d66b0a1fc3295f2ce85c8dad15ee795fa1764.
- Four isolated numerical preparations and10/10 HDL children PASS, four successful
  simulations, no failed attempt, repair or automatic retry.
- 184 checked responses,248 commands,23992 accepted stimulus samples,68 resets,
  four injected divider faults/recoveries,559 held-result cycles,22476 II1 checks.
- D16/cap4096/MAX_M64 sim:122935 maximum observed wait clocks,1.359 seconds.
  This is finite simulated service behavior, not a hardware frequency/rate claim.
- Exact even/odd half ties, exact maximum sum bound, maximum denominator,
  full-width invalid commands, strict LAST and invalid precedence passed.
- Real PRE0/POST255 ring composition passed;300 invalid pretrigger observations
  were discarded before the retained trigger+255 record.
- All simulation and preparation stderr is empty. Compile stderr contains only
  missing time-unit/precision warnings. Syntax stderr is empty.
- All18 current inputs, checked archives, vectors, summaries and tools retain
  receipt-bound hashes. The frozen README remains a pre-execution specification;
  this status and QUALIFICATION.json are the authoritative post-run supplements.
- Package attributes were '* -text' from inception. Checked archival attributes
  were data-named '.gitattributes.executed.txt' before any preparation; no source
  rename or normalization exception is required.
- Four successful .build images are retained with exact hashes. No worker cleanup,
  staging, commit, old regression, combined compile, synthesis, PnR, STA, board
  work or PPA measurement was performed. B40 and historical evidence are untouched.

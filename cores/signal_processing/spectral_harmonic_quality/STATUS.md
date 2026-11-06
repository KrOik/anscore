# B42 spectral_harmonic_quality qualification

Current status: LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.
The root independently reviewed the full19-source closure and explicitly gated
one original finite attempt. The frozen README remains the pre-run specification;
this file and QUALIFICATION.json are the authoritative post-run supplements.

- Baseline:2e7a6fb51f32e525c1026c28d1f2f45e36545ebc.
- Plan SHA256:af4921ad1096a87cc2448d90265972dc0c056e24dda12fc4e121e4dc0260a6a2.
- Seal SHA256:9472a5078792c47c3c16e1cc208138a073065f2711c397387bdb3e1e9088dd57.
- Receipt:reports/20261106T082939_672565Z/results.json.
- Four isolated numerical preparations and10/10 HDL children PASS, including
  two syntax checks and four compile/simulation pairs; no failed attempt,
  repair, automatic retry or changed frozen input.
- 262 commands/cases,214 checked responses,8912 accepted input samples,
  52 resets, four injected divider faults/recoveries,1070 explicit held-result
  checks and8718 II1 readiness checks. All12 active states were cancelled and
  followed by healthy recovery in each profile. Next actual configurations
  were held during old output stalls until their real handshake.
- Lmax12/N4096/TAG32 simulation maximum post-input wait2263 clocks,0.234s;
  actual I/Q chain maximum wait335 clocks,0.188s. These are finite simulated
  behavior, not physical clock/sample-rate measurements.
- Exact positive-interior total/fundamental/per-harmonic/residual partition,
  r0/1/2 windows, H2/8, early peak ties, search-outside strong bins, maximum
  u32 power/capacity, even/odd THD and SNR half ties, zero denominator flags,
  full-width malformed commands and LAST/invalid precedence passed.
- The actual unchanged mag_squared signed16 I/Q composition passed, including
  marker/invalid alignment, early LAST stop, reset cancellation and recovery.
- All simulation/preparation stderr and both syntax stderr are empty. Compile
  stderr contains only missing time-unit/precision warnings.
- All19 current/archived source inputs, four vector/summary pairs, raw logs,
  tools and four retained successful images match receipt hashes. The runner
  recorded each completed child before parsing metadata; each simulation's
  image digest matched its prior compile record before launch and at closeout.
- Local attributes are exactly '* -text' with LF; archived attribute data was
  named '.gitattributes.executed.txt' before preparation. Frozen sources and
  evidence bytes are preserved. No worker cleanup, staging, commits, inherited
  tests, combined suite, synthesis, PnR, STA, board or PPA work was performed.
Receipt SHA256: 3ae952ad90f4e60b7d97fc0e174dfea22487edb58f122d357727bb3f70c616b1.

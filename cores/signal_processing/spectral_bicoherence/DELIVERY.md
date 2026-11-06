# B45 spectral bicoherence delivery

The gated run [20261106T132149_298328Z](reports/20261106T132149_298328Z/results.json) passed: **5 numerical preparation children and 12 HDL children**, comprising 2 Icarus syntax checks, 5 compilations and 5 unit simulations. Current qualification is **ICARUS_SYNTAX_COMPILE_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. The effective B45 feature commit is pending root-controlled Git work.

This later delivery and [QUALIFICATION.json](QUALIFICATION.json) record the completed execution. README.md, manifest.json, STATUS.md, the prospective plan, seal and review remain frozen consumed records. Their earlier source-only statements describe the pre-run state.

The core reduces caller-supplied complex spectral triples to exact B/U/V sums and squared bicoherence with one final ties-to-even rounding. The included adapter selects static bins from complete natural-order spectra and forwards actual triples to this core. It contains no FFT. One unchanged local serial multiplier and one integer divider are reused; no code was copied from the GPL reference project.

| Simulation profile | Cases | Commands | Results | Input beats | Timing checks |
|---|---:|---:|---:|---:|---:|
| Core D2/MAX1/T1 | 10 | 28 | 24 | 10 | 5 |
| Core D12/MAX9/T8 | 14 | 36 | 32 | 77 | 9 |
| Core D16/MAX256/T32 | 3 | 6 | 6 | 512 | 2 |
| Adapter D12/MAX64/T8, BINS17, bins2/5/7 | 14 | 36 | 32 | 1293 | 9 |
| Adapter D2/MAX1/T1, BINS1, bin0 | 10 | 28 | 24 | 10 | 5 |
| Total | 51 | 134 | 118 | 1902 | 30 |

These totals include 51 future commands and51 future results, 21 resets and16 cancelled accepted commands. The suite counted846 held-result cycles,26818 blocked command cycles and549221 blocked input cycles. Future counts are included in command/result totals. Every observed marker field matched the frozen plan and receipt.

Directed cases cover zero/undefined energy, signed minima, quadrature, cancellation, malformed LAST, full32 invalid K, K1 behavior, K256 extrema/mixed input, ties0.5→0 and1.5→2, stable held interfaces, actual later handshake of future commands after original result retirement, no retirement fallthrough, and four reset-abort phases with recovery in the four nonmaximum profiles. **MAX9 tests legal K1/K8; K9 was not simulated.** The MAX256 core tests full K256 but has no reset-abort scenarios. The MAX64 adapter tests legal K1/K8. ARITH error branches were source-reviewed only; no fault injection was performed.

An independent audit used inline PowerShell reads, JSON parsing, SHA256 and byte comparisons. All **750 assertions** passed:19 current and19 archived source bindings,4 declared executable tool pins, current/archived plan/seal/review, once-lock, exact17-child sequence/argv/cwd/PATH,34 raw streams,5 vector/preparation receipts and5 compile/executed-image bindings. Consumed bindings are rehashed after writing these two new files. Qualification performed no numerical/model/HDL/helper/Git execution or cleanup.

All17 original recorded PIDs have PASS/exit0, process-exited, finalized-raw and saved-process evidence with empty cleanup. No active child/helper is recorded. Longest execution: **2.578s**; longest total child elapsed:2.594s. All children satisfy the20s deadline. The sealed lifecycle is20s child /5s tree helper /sole2s target exit observation, fail-stop and no automatic retry. Timeout/tree-kill exceptional paths were not exercised. Original recorded exit evidence, rather than current PID absence, supports the exit qualification.

Compilation passed with retained missing-time-unit/precision warnings:530 stderr bytes per core compilation and634 per adapter compilation. Syntax, preparation and simulation stderr are empty. Warning-free status is not claimed.

| Evidence pin | SHA256 |
|---|---|
| results.json | 72752467da059d50500345ff61fdc92d2c0871447e6f7a28fc1022e15dcff7a7 |
| PRECHECK_PLAN.json | fe1013e1a5308045f7532fc34e29b1a8c1de7ee8ac3c271037994bf3459d8a02 |
| SOURCE_SEAL.json | 26de0932aa69afa9455e576d49146cce62da459d92170660877c2d7891d47652 |
| SOURCE_REVIEW.json | 56e8c050f9f586f54cece04eff691d509a52f88066ee88cb35380827a1411e03 |
| run_checks.py | 01cfa4c5457e4a432ee1a07606cb2929dcf6475ba6ef91e987a307ea1c226120 |
| EXECUTION_LOCK.json | f7877162e47f06d9902431a64fa350b7e54e0f86f93219c3a456d8cad19654d7 |

Baseline:a0602fb2dac20db7c524297371a19f5f580980df. QUALIFICATION.json includes complete observed counters, recorded PID/time/exit evidence and independently verified source/tool/raw/vector/image hashes.

Finite deterministic unit simulation does not establish formal proof or exhaustive parameter coverage. Synthesis, PnR, STA, board/PPA, measured FPGA resources/Fmax/physical rates, inherited regression, combined full-repository compilation and external FFT integration were not run. Default2220 core storage bits plus103 adapter bits are logical source estimates, not measured FPGA flip-flops. Timing checks validate modeled first-valid clock counts; pauses and backpressure affect system elapsed time.

The caller owns segment alignment, frequency-grid/sum-frequency semantics, windowing and scaling. Every nonzero K1 triple yields unity and supplies no evidence of coupling. No significance threshold, confidence interval, surrogate analysis, causal inference or calibrated-detector qualification is supplied.

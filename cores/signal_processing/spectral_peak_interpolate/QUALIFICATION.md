# Immutable finite qualification

BASE `d32ea87e268c5957b7203560a5b46864e282a6e1`.
The executed gate was `B47_SPECTRAL_PEAK_INTERPOLATE_ONCE_01`, with root and
independent worker_c full source review. Preparation and HDL execution began
only after both approved the exact final plan and source seal.

| Frozen control | SHA256 |
| --- | --- |
| PRECHECK_PLAN.json | d891d2685f39ca2ea56bad68b2808207855d734273e6a78d2aaf113594095239 |
| SOURCE_SEAL.json | b11be955d558f5d6fc3f4d1a525b8ee41dca7db23a925fbe65d0bf67ca00a845 |
| run_checks.py | 1786c27278930d5ee8efc284f976f8dfb528a6da92e085c37e0035490d75a82c |
| reports/20261106T152538_080888Z/results.json | a34ca8cc9fd3cef14c29df074a66120182cba9e225c2264e86de48806faf4061 |

The receipt is PASS with suite_complete, inputs_unchanged and
exact_plan_executed true; active child/helper are null. Its17 source hashes
include14 original new files and3 unchanged production dependencies;24 tool
hashes,17 source archives,14 terminal child JSON files,28 raw streams,
four vector/preparation pairs andfour retained images are recorded.
The runner imported no project oracle; four isolated direct oracle executions
produced four preparations. Planning used zero model imports, numerical
preparations, AST executions or HDL children. There was no automatic retry.

| Profile | MAX_LOG2N / TAG_W / input | Responses | Holds | Cancellations / recoveries | Consecutive accepted pairs |
| --- | --- | ---: | ---: | ---: | ---: |
| core_min | 4 / 1 / power32 | 46 | 184 | 14 / 14 | 581 |
| core_default | 8 / 8 / power32 | 46 | 184 | 14 / 14 | 1386 |
| core_max | 12 / 32 / power32 | 46 | 184 | 14 / 14 | 10115 |
| iq_default | 8 / 8 / signed16 I/Q | 46 | 184 | 14 / 14 | 1386 |

Each profile checks32 generated normal/error transactions and14 successful
fresh-frame recoveries after cancelling all active states1..13 and a partial
load. Four-cycle held responses preserve every output. The actual input-fire
counter proves continuous accepted bursts alongside deterministic gaps.
Both entry points require strict vector EOF. All four simulation stderr
streams and both syntax stderr streams are empty. No child needed termination.

Coverage includes maximum frame4096, full unsigned32 power, I/Q signed minima,
zero and tied spectra, local/nonlocal band-boundary peaks, flat curvature,
half-bin vertices, positive RNE ties, threshold equality/rejection,
configuration high-bit rejection and LAST/invalid precedence. A windowed
complex-tone DFT fixture demonstrates FFT-like inputs without importing an FFT
or copying the hardware schedule into the oracle. This finite matrix does not
prove all possible inputs, windows, arbitrary stalls or physical accuracy.

The original authored README/manifest say execution pending because their
bytes are frozen execution inputs. This separate additive qualification is the
current maturity statement. No frozen RTL, source list, TB, model, runner,
plan, seal, review, vector, raw stream, receipt or image was rewritten.
No synthesis, PnR, STA, board test, PPA or mature-asset regression ran.

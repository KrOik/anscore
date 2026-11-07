# B50 finite qualification

Status for the exact RTL/TB/dependency bytes sealed by followup01/FINITE_PLAN.json:
LINT_PASS + UNIT_SIM_PASS; wrapper INTEGRATION_CANDIDATE; HW_UNVERIFIED.
The earlier frozen README/manifest NOT_RUN labels describe the source freeze.
This additive note records the subsequent observed finite check only.

The original attempt remains FAIL_STOP: one preparation SyntaxError, exit1,
zero HDL launches and zero images. Its source, raw evidence and guards are
unchanged. The additive followup01 repairs only the model record formatter;
no RTL, quantizer, expected answer, traffic, timeout or test was changed.

The separately reviewed follow-up ran once: one preparation plus12 HDL targets
(four syntax checks, four compiles and four simulations), all13 exit0. The
outer supervised runner exited0 in15.531s including capture, within20s. No
termination helper, timeout or unconfirmed process remains. Root and independent
worker_b audited the frozen command order,18 current/archived source pins,
26 tool pins,13 initial/terminal/validated record sets, raw captures and four
retained images. The image SHA/prechecked fields were exclusively written and
fsynced in each immutable initial record before Popen.

| Profile | MAX_ROWS | TAG_W | Wrapped | Commands observed | Outputs checked | Reset probes | Cycles |
|---|---:|---:|---:|---:|---:|---:|---:|
| tiny | 1 | 1 | 0 | 35 | 88 | 7 | 5402 |
| ragged | 3 | 17 | 0 | 35 | 136 | 7 | 6242 |
| maximum | 64 | 32 | 0 | 35 | 1600 | 7 | 31860 |
| example | 8 | 32 | 1 | 37 | 260 | 8 | 8769 |

Total2084 outputs were compared to direct spatial integer sums and quantization;
521 separate transform identity checks were performed by preparation. Coverage
includes valid configuration/publication, atomic rejected writes, invalid command
counts, missing publication, malformed LAST, signed extremes, RNE ties,
saturation/zero-point translation, deterministic stalls and live reset probes.
These are finite witnesses, not an exhaustive proof or whole CNN/frame test.
Compile captures retain warnings that RTL modules have no explicit time unit;
preparation and simulation stderr are empty. No synthesis, PnR, STA, board,
PPA or historical regression was run. No resource, timing or power claim follows.

Evidence:
- reports/20261106T201511289779Z/results.json (original failure)
- reports/followup01_20261106T202707954860Z/results.json
  SHA2566ec6ff0c557f2a1266739d667a8af5277a10061ea85f9f49fd48f6380f28697d
- repository-local .git/anscore-b50-winograd-followup01-launch/results.json
  SHA25698a8320861e0de6c24c36e63f9a09043050491dd4628f2b0111e7061087da260
- followup01/SOURCE_REVIEW.json (root + worker_b exact gate)

Use followup01/model/reference.py for the corrected offline vector generator.
The original model/reference.py is intentionally retained as failed evidence.
Both one-attempt paths are consumed and must not be invoked again.

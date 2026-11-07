# Retained qualification record: outer timeout and completed inner checks

Overall result: **FAIL_STOP / outer TIMEOUT** for the sole
B50_TONE_FIT_ONCE_01 attempt. The outer finite_runner record reports
20.90600000001723 seconds, including capture and cleanup, against its
20-second execution limit. The overall bounded qualification did not pass.
No automatic retry occurred. Hardware remains **HW_UNVERIFIED**; synthesis,
PnR, STA, board testing, PPA and historical regression remain NOT_RUN.

The retained inner controller independently reports status PASS,
suite_complete=true and exact_plan_executed=true. All 15 planned inner
children completed: four preparations, four compilations and four simulations
were actual PASS / exit 0; three deliberately invalid parameter elaborations
were actual FAIL / exit 1 and separately validated as expected rejections.
Their original FAIL records are retained. Each rejection capture contains
Unknown module type and the specified
known_phase_tone_fit_invalid_parameter__see_CONTRACT marker. These finite
observations do not change the outer timeout into an overall PASS.

## Observed simulation counters

The following are the actual raw simulation markers. Cycles are testbench
clock counts, not physical timing or measured FPGA performance.

| Profile | Fixture cases / results | Accepted commands | Accepted sample beats | Held-result cycles | Reset edges | Testbench cycles | Example |
|---|---:|---:|---:|---:|---:|---:|---:|
| minimum | 11 | 16 | 27 | 51 | 19 | 15458 | 0 |
| typical | 16 | 21 | 82 | 71 | 19 | 42381 | 0 |
| maximum | 19 | 24 | 850 | 83 | 19 | 340778 | 0 |
| example | 19 | 24 | 850 | 83 | 19 | 340779 | 1 |

Four simulations retired 65 fixture results. The model fixtures contained
1777 sample beats (19+74+842+842). Each testbench also accepted five reset
probe commands and eight reset probe sample beats. Thus the actual totals
were 85 commands and 1809 sample beats: 65+20 commands and 1777+32 samples.
Each profile observed 19 reset edges: four during initial startup and three
for each of the five cancellation probes. All four simulations emitted one
PASS marker, completed through $finish, and had empty stderr. The captured
counters agree with their immutable validated sidecars and the frozen plan.

## Outer termination evidence and its limit

The outer target was PID 23044. Its terminal status remains TIMEOUT although
its final observed exit code is 0. Timeout cleanup launched taskkill PID 25992;
the helper exited with code 128 in 0.875 seconds. Its original OEM stderr says that
process 23044 was not found. The target-exit observation records 0.0 seconds.
Both target and helper are recorded as exited, capture is complete, and the
final active_child, active_helper and active_helpers fields are empty.
No inner child timed out or used a cleanup helper.

The retained control flow entered timeout cleanup, while the target was gone
by the helper's process lookup. This is consistent with target completion
racing the deadline and cleanup observation. The records do not provide an
absolute inner completion instant or a shared recorded start/end instant
that establishes its exact order relative to the outer 20-second deadline.
A final exit 0 or a complete inner PASS receipt cannot establish an on-time
outer completion. No exact completion time is reconstructed and no original
outer status, terminal record, capture or guard has been rewritten.

## Read-only evidence audit

Root and independent worker_c audited the retained evidence with native file
reads and SHA256 hashing. No project/helper/model/HDL code was rerun for this
audit. The audit found no mismatch among the 19 current and archived source
pins, 32 tool pins, archived/current plan/seal/review pins, all 15 initial,
terminal and validated sidecars, all 30 inner raw captures, outer captures and
helper captures. All seven outer evidence files and all 106 inner report
files were retained. The four VVP image hashes agree with their compile
validation, execution-image receipt and exclusive pre-Popen initial sidecar
(status STARTING, pid null, execution_image_prechecked=true).

| Retained image | SHA256 |
|---|---|
| minimum.vvp | b80f3969ccc36e709991cdb5886dd2172a7d285c5f7da871366867b8d172298e |
| typical.vvp | 575601288f39a0ea176837f8e24e58634dbfb0869e9912f2cde3901bfa60eb6c |
| maximum.vvp | f587ca6d89d895ab5d471fe1088879744c0002c5aa49042489e4bb9c4117739a |
| example.vvp | ed198b89aaab0ea2f2deab770103619a85ca7d2e8574ff1a95108a66ac70e7f2 |

Baseline: c9117a22459e954d496dfa66dd94d6f67188c862.
The original once guards remain present and forbid reuse of the attempt.
This additive note records the outcome; it does not authorize another run.

Primary retained evidence:

- Package-relative reports/20261106T203014567938Z/results.json:
  46802 bytes, SHA256
  1a778e1b5c5aa50de620ca70a5eb2eb3bae668f05e813bf1c414ede764e33c84.
- Repository-relative .git/anscore-b50-tone-fit-launch/results.json:
  2826 bytes, SHA256
  6deeef1cc65bbbcf4cf19fd3c3bf86e01959fb3a98c100b0f74e4d2e8e169c83.
- All original plan/seal/review archives, 15 child initial/terminal/validated
  sidecars, raw stdout/stderr, four vector/manifest pairs, 19 source archives,
  four compiled images and both once guards remain at their original paths.

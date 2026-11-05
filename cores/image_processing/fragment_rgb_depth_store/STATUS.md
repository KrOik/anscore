# B35 qualification

LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.
First finite run: `reports/20261105T183457648821Z/results.json`.
All 10 children PASS; one preparation attempt/completion, no retry, no executed
input changes. Three store simulations compare 50020 RGB/Z raster words;
actual triangle/store composition compares 4096, total 54116. Maximum 128×128
three-frame export completes in 5.44 seconds. Both smaller profiles exercise
reset/recovery across 8 phases plus initialization and held raster/DONE.

Source/metadata bridge is `B35_DELIVERY.json`. Shared triangle source is
byte-identical to the baseline/archived source. Complete parameters, protocols,
arithmetic, cycle counts, resource risks and test limits are in README.md.

Maximum 655360-bit frame RAM has HIGH device-capacity risk. No synthesis,
PnR, STA, board or power was run. Resource/clock/video-rate claims are unmeasured.
No shared edits, stage/commit or cleanup are performed by this worker.

# B34 qualification

Production RTL was unchanged throughout both attempts and remains byte-identical
to the archived checked source. Maturity is LINT_PASS, bounded UNIT_SIM_PASS,
and HW_UNVERIFIED. The original overall full suite is TIMEOUT, not PASS.

Original receipt `reports/20261105T180820675307Z/results.json`: one preparation
attempt/completion ; 11 children PASS and maximum 128脳128 full playback TIMEOUT.
Four passing simulations compare 3416 pixels, exercise per-command exposure,
integer rounding, black/full-scale frames, CE/marker/backpressure/error handling,
reset/abort phases and recovery. Both default and full-port example lint pass.

Directed receipt `reports/20261105T181323884558Z_max_prefix/results.json`:
one preparation attempt/completion, no vector regeneration, original hashes
verified; two new children PASS. Full 128脳128 capture/statistics and 64 output
pixels compare before intentional abort. The full maximum playback remains
unqualified by deadline despite late raw completion output. Combined accepted
scope is 3480 output comparisons and 13 PASS children; the retained TIMEOUT
is explicitly excluded from PASS. No original HDL/input rerun followed it.

No synthesis, PnR, STA, board or power check was run. Maximum 96 KiB frame RAM
has HIGH device-capacity risk; default RAM is 4.5 KiB. The serial 129-enabled-cycle
output interval is an RTL schedule, not a video-frequency guarantee.

Only this new package is authored. No shared file, staging, commit or cleanup
is performed by this worker. Parent owns post-delivery temporary-image cleanup.

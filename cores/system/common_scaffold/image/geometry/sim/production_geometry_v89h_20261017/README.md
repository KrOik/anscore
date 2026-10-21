# Final-candidate production geometry integration

`run_final_candidate_production_geometry.py` is the explicit-candidate release
and read-only production-integration runner. It accepts only a direct child of
`cores/system/common_scaffold/board/tang25k/build/`; it never applies candidate
RTL to production. The default `--production-state baseline` requires the six
production frame-chain files to match the preserved pre-candidate snapshot.
Use `--production-state candidate` only when all six production files already
match the selected candidate byte-for-byte.

Run the selected candidate's own mapper and sampler regressions first:

```powershell
python -B cores/system/common_scaffold/image/geometry/sim/production_geometry_v89h_20261017/run_final_candidate_production_geometry.py `
  --candidate image_geometry_frame_selftest_25k_20261017_v89l `
  --local-regressions-only
```

Check whether its frozen release evidence is complete:

```powershell
python -B cores/system/common_scaffold/image/geometry/sim/production_geometry_v89h_20261017/run_final_candidate_production_geometry.py `
  --candidate image_geometry_frame_selftest_25k_20261017_v89l `
  --preflight-only
```

The full read-only integration uses the same explicit candidate argument and
omits either mode flag. It reruns the candidate's mapper/sampler tests in
staging, checks its immutable freeze and release evidence, then runs production
geometry regressions against copied RTL. A successful full integration writes
one compact result JSON in this directory. Failed runs do not write a result.

The release gate requires a candidate freeze, six passing functional/wrapper
simulation suites with the original UART bytes, fresh mapper and sampler
evidence, passing official synthesis within the device limits, a corrected-
chipdb 50 MHz route with setup and hold passing, matching bitstream hashes,
and three independent SRAM-only board-load records with exact UART captures.
The currently staged v89l candidate does not yet have
`board_validation_summary.json`, so its preflight is expected to reject until
those board records are produced.

All generated test benches, simulator images, candidate-local regression
outputs, and logs are kept in a uniquely named temporary directory under this
runner directory and removed automatically on success or failure. The
local-only mode leaves no persistent output. The full mode retains only its
compact result JSON. No candidate files, production RTL, or pre-existing build
artifacts are rewritten or deleted.

`run_production_geometry.py` is the earlier v89i-pinned runner retained for
historical reference. New candidate work should use the explicit-selection
runner above so the tested candidate cannot be inferred from stale paths.

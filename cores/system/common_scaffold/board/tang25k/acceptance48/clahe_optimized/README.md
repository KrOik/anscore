# CLAHE exact bounded candidate: case_v8

Current RTL is `candidate_v8/cip_image_clahe.v` and
`candidate_v8/cip_image_clahe_frame.v`; frozen board candidate is `case_v8/`.
Production RTL, shared generators/build scripts, old orphan processes and old
temporary paths are unchanged. No JTAG or programming was performed.

## Current result

- Complete original independent CLAHE reference PASS:1047 commands,59357 exact
  output comparisons,9 reset cases; all five original width/gray profiles,
  source stability and empty compiler diagnostics. Evidence:
  `evidence/clahe_pipeline_candidate_v8_20261018T154457Z_dc225446/summary.json`.
- Frozen seven UART normal/fault/watchdog simulations PASS; original digest
  `A48 434C4148 PASS E=00000000 D=86E06FA4 T=0` is unchanged.
- Actual serial fraction RTL:4828 exact floor comparisons for all nonnegative
  offsets<=span<=68, including UNIT endpoints, PASS.
- Extra clip/count bound regressions:15218 exact outputs across8/32-bit,
  MAX34x34 and actual board MAX8x6, full/partial tiles, clips at count capacity,
  above capacity, powers that would truncate to zero, and0xFFFFFF, PASS.
- Synthesis/route resources PASS:4070 LUT4-class,879 DFF,8 BSRAM,0 MULT12.
- Pre/post-route setup:55.46/51.95MHz, PASS50MHz. No clock exception was added.
- Shared strict build result is `ROUTE_GATE_FAIL_NOT_PACKED` solely because
  hold timing/model qualification is unproven. No bitstream or board PASS is
  claimed. Root may continue its existing bounded FUNCTIONAL_BOARD_ONLY path.

## Exact changes

Runtime grid ceil division selects constant divisors using narrow numerators
and retains16-bit grid counts for correct >256-tile rejection. Neighbor choice,
center offsets/spans and fraction calculation occupy distinct CE states.
Fractions use8-step restoring division, giving exact floor(offset*256/span).
Odd tiles,1x1 tiles, actual partial-tile area and doubled-coordinate centers
are preserved. RAM reads remain synchronous. Frame addresses have explicit
32-bit arithmetic context; the narrow tile-area product is zero-extended to
its original64-bit interface before existing part selects.

The public wrapper sizes histogram/CDF counts to ceil(log2(MAX_PIXELS+1)).
No legal frame or tile count can exceed MAX_PIXELS. Clip thresholds above this
bound cannot clip a bin, so they are equivalently clamped to MAX_PIXELS before
being passed to the narrowed helper. The helper's standalone default remains
24 bits. The LUT RAM covers256*min(256,MAX_PIXELS) entries, the exact maximum
legal tile count for the elaborated dimensions. No golden or watchdog changed.

## Reproduce

```powershell
python cores/system/common_scaffold/board/tang25k/acceptance48/clahe_optimized/run_full_reference_v8.py
python cores/system/common_scaffold/board/tang25k/acceptance48/clahe_optimized/run_serial_fraction_v8.py
python cores/system/common_scaffold/board/tang25k/acceptance48/clahe_optimized/run_clip_bound_tests.py
python cores/system/common_scaffold/board/tang25k/acceptance48/clahe_optimized/run_board_clip_bound_tests.py
python cores/system/common_scaffold/board/tang25k/acceptance48/clahe_optimized/stage_candidate_v8.py --output <fresh-case-directory> --verify
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py <fresh-case-directory> --attempt clahe_bounded_count_v8 --no-lutram
```

The full reference retains the original independent histogram/strict unit
redistribution/CDF/actual-center numerical model and original fixtures. Three
supported profiles run concurrently in independent temporary directories;
rejection profiles also run. Temporary binaries/fixtures clean up on exit.
Small logs, hashes and failed frozen candidates remain for review.

## Retained failures

- Original clahe_v1:1200-second synthesis timeout; not rerun. Previously denied
  orphan cleanup was neither retried nor bypassed.
- case_v2:resource PASS, setup31.96/25.32MHz FAIL.
- case_v3:original full case325 exposed out-of-range tile-area part selects,
  disabling CDF shortcuts and triggering the unchanged2M-cycle watchdog.
- case_v4:complete runner rejected dimension-port padding diagnostics.
- case_v5:original full case327 exposed self-determined RAM-address narrowing
  and wrap above512 pixels. Original golden was not modified.
- case_v6:full reference PASS, resource PASS, setup37.52/31.32MHz FAIL.
- case_v7:full reference PASS, resource PASS, setup54.73/41.41MHz FAIL.

Root-cause regressions for original cases325/327 remain alongside their logs;
all original cases pass in final v8. Detailed hashes/status: `HANDOFF.json`.

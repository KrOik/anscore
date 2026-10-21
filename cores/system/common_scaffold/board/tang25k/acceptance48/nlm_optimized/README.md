# Isolated NLM candidate v10

Current result: all original independent NLM profiles and seven UART cases PASS.
Same OSS -noalu/seed3 flow passes resource and50MHz setup gates:3470 LUT4,
1356 DFF,2 BSRAM,0 MULT12; pre/post route65.51/53.15MHz.
Shared strict build is NOT_PACKED only because hold/min-delay model remains
unqualified. Root completed three real SRAM/UART runs PASS; evidence case_v10/functional_board_nlm_bounded_control_v10_20261019_004733_573478.json.
Root-authorized production integration copied the two exact v10 sources and updated NLM dependencies; full production NLM regression passed334 commands/4266 outputs/12 resets. This task did not access JTAG. Frozen candidate/case and hashes
are recorded in HANDOFF.json. Original NLM baseline1200s timeout is retained.

## Verification

Original reference/testbench/watchdogs are unchanged. Six profiles PASS:
334 commands,4266 numerical outputs,12 reset cases, source stability PASS.
Evidence: evidence/nlm_serial_v10_20261018T164252Z_3c48f525/summary.json.
All seven frozen UART paths PASS including corrupt pixel, timeout, terminal
response error, illegal ISSUE output/response and lingering NEXT response.
Normal UART remains `A48 4E4C4D44 PASS E=00000000 D=983E00FF T=0`.
Actual arithmetic checks PASS544:260 full64-bit quotient/remainder vectors,
9 original operation-launch/truncation probes,15 extra threshold/zero probes,
and260 exact mod2^64 multiplications. See arithmetic_checks_v10_summary.json.

```powershell
python cores/system/common_scaffold/board/tang25k/acceptance48/nlm_optimized/run_reference_v10.py
python cores/system/common_scaffold/board/tang25k/acceptance48/nlm_optimized/run_arithmetic_checks_v10.py
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/nlm_optimized/case_v10 --attempt NEW_UNIQUE_ATTEMPT --no-lutram
```

To freeze a new case, stage_v10.py --output NEW_EMPTY_DIRECTORY --verify.
Do not overwrite retained cases. Temporary fixture/binary directories are
removed by TemporaryDirectory. Build/validation evidence is intentionally kept.

## Exact arithmetic and integration

Private img_filter_nlm_serial_engine replaces only the NLM dependency.
Keep production img_filter_frame_engine.v and accepted morphology unchanged.
Copy/add the two candidate_v10 files per HANDOFF.json, then update NLM-specific
source lists/dependency registry/generator/test runner to include the new helper.
No public wrapper interface changes are needed. Integration belongs to root.

Unsigned64-bit `(ssd <<20)` truncation and rounded-addition wrap are explicit.
For nonzero d, floor(n/d)>=2^b iff(n>>b)>=d. Four16-bit subtraction cycles
check this exact threshold. Saturating index emits255 when b=8 overflows;
normalization emits max pixel when b=PIXEL_W overflows. Otherwise the full
64-bit shifted remainder initializes exactly b restoring bits. Each bit uses
four16-bit subtractions plus initialization. Division by zero returns zero.
Normalization first performs the original64-bit addition in four16-bit words.
Per-frame h*h*patch_size uses two exact64-bit serial multiplications,256
cycles each, with16-bit carry propagation; all products preserve mod2^64.
Exp LUT weight and four4-bit weight*pixel products are independently registered
and combined in two phases. Weight/weighted sums use split16-bit carry updates.

For valid12-bit pixels and configured radii<=255, PATCH_COUNT and SEARCH_COUNT
are each <=261121. SSD <2^(2*PIXEL_W+ceil(log2(PATCH_COUNT))), weight sum
<2^(16+ceil(log2(SEARCH_COUNT))), and weighted sum needs PIXEL_W more bits.
Updates are bounded accordingly, explicitly zero-extended to64-bit registers.
Counts and signed coordinates are bounded by elaborated maxima; offsets are
signed9-bit [-255,255]. Synchronous frame addresses retain explicit32-bit
context, avoiding self-determined index truncation. OP0/1 paths are retained;
constant OP guards prune unused morphology address/RAM logic for NLM OP2.

Worst8x6/pr1/sr3 nonsaturated8-bit frame is about271136 enabled cycles
(including512 setup multiplication cycles), about316326 physical cycles under
the original TB6/7 CE pattern before small I/O stalls, below its unchanged
500000 per-command watchdog.12-bit normalization adds960 enabled cycles.
No fixed-cycle output contract is claimed; original CE/backpressure tests pass.

## Retained attempts

|Candidate|LUT4|DFF|BSRAM|MULT12|Pre/post MHz|Setup50|
|---|---:|---:|---:|---:|---|---|
|v1|4870|942|2|0|17.57/14.49|FAIL|
|v2|4739|1043|2|0|16.77/13.34|FAIL|
|v3|4050|1029|1|0|17.16/15.51|FAIL|
|v4|4205|1246|1|0|19.96/18.0|FAIL|
|v7|4241|1456|1|0|38.82/31.9|FAIL|
|v8|4004|1523|2|0|49.61/46.15|FAIL|
|v9|4019|1558|2|0|55.06/46.72|FAIL|
|v10|3470|1356|2|0|65.51/53.15|PASS|

V5 is rejected because original w1/g1 case63 reached its unchanged500000-cycle
watchdog; its seven UART tests passed but that does not override the failure.
V6's initial run was interrupted following a source edit and is not accepted
source-stable evidence. V7 onward retains fast exact saturation checks instead
of the overly slow V5 full quotient loop. All failed candidates/logs remain.

Production integration PASS: production_integration_summary.json; production six-profile evidence evidence/nlm_serial_production_20261018T165008Z_328bfc10. Shared image_core seven-case regression (including opening/closing/guided) and all functional-source compilation PASS; protected shared-engine/guided hashes unchanged. Reproduce production: `python cores/system/common_scaffold/signal_video/run_nlm_serial_tests.py`.

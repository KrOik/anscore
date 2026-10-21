# Public entry board functional validation

2026-10-18:1/48 public entries have new bounded functional board evidence.
Historical underlying-core tests remain separate in COVERAGE.md.

| Public entry | Result | Scope/evidence |
|---|---|---|
| cip_image_brightness_contrast | 3 SRAM/UART runs PASS | cases/brightness_v5/functional_board_accept_20261018_215859.json |

All new results are FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN, not timing signoff
or complete delivery acceptance. The open-source fast-min/hold model remains
unqualified. Resource and50MHz setup gates are enforced; reported hold
violations block programming. Current test harness uses CE_DIV4. Each candidate
freezes source/fixtures, compares full output words/markers/tag/error in RTL,
and checks exact UART bytes after actual JTAG programming. Fault-injection and
watchdog simulations must pass first. No SPI flash is written.

Brightness v3/v4 setup failures are retained; v5 fixes only the self-test
harness counter/reset paths. Connection preflight common_uart PASS is not one
of the48 entries. Gamma/scaler/DSP builds are pending; other entries remain open.

## Current continuation

Local JTAG initial detect0x1281b and COM44 open succeeded. UART smoke SRAM
preflight passed. After brightness three actual runs passed, a subsequent
provenance-hardened rerun failed at FTDI USB open(-4) before programming.
User was asked to reconnect JTAG; connection failure is not a functional PASS.
Gamma_v3 setup54.55MHz, invert_v1 setup53.36MHz and FIR_v5 setup55.46MHz
pass resource/setup gates and await physical validation. Hold remains UNPROVEN.
IIR_v5 setup fails and is not programmed. Scaler_v3 build is still running.
Build/board scripts preserve failed attempts and freeze source, netlist,
route JSON, constraints and expected UART provenance before programming.

## JTAG restored and first batch complete

JTAG again detects0x1281b. Brightness, Gamma, invert, FIR and CORDIC each
completed three independent SRAM loads and exact UART comparisons. Current
bounded functional board coverage is5/48; all remain hold-unproven and this is
not complete delivery acceptance. Brightness was repeated using the hardened
route/source/fixture provenance binding. See acceptance_status.json and
ACCEPTANCE_STATUS.md for per-entry records generated from actual evidence.

HE/histogram encounter block-RAM port mapping failures, retained in logs;
CIC/IIR/resampler/FFT/color-conversion setup failures remain unprogrammed.
Mapping/timing fixes and remaining fixture preparation continue in parallel.

## Latest batch:11 public-entry implementations functionally tested

New successes are mirror, histogram, CIC optimized, IIR optimized, HE and mean
filter, each with3 actual SRAM/UART runs. IIR is now integrated in production
with registered multiply/accumulate/quantize; full DSP group PASS at
`evidence/all_20261018T142306Z_a7da67c2/summary.json`. Original numeric goldens
are unchanged; the original IIR TB wait bound changes9→32 for the documented
longer latency. HE final helper is integrated and passed11-profile histogram
regression (617 commands/155196 outputs/44 resets). Histogram needs a new
production-helper board run; its earlier candidate version differs internally.
CIC remains a board-proven candidate pending integration. All board results
remain bounded and hold-unproven. Gaussian/median builds and FFT optimization
are running; scaler initial synthesis timed out at1200seconds, not restarted.

## Latest:12/48 bounded functional board implementations

Gaussian filter completed3 actual SRAM/UART runs. Histogram was also rebuilt
and retested using the integrated final058a helper, so its current production
internal source is now covered independently of HE. IIR current production
passes DSP regression and matches its board-tested candidate. CIC candidate
still needs production integration. Ledger preserves pending candidate changes.
Median and CCM first placement failed setup narrowly; one alternate seed is
under test, without relaxing gates or changing numeric fixtures. FFT's first
pipeline candidate improves23.67→44.17MHz but still fails50MHz; work continues.

## Latest:14/48 bounded functional board implementations

FFT optimized case_v3 completed three real SRAM/UART runs with unchanged
digest 7587C122. Its exact core is integrated into production; DSP full-group
regression passed at evidence/all_20261018T143314Z_0fe3dc9f. Resources:
2486 LUT/765 FF/4 BRAM/0 DSP; setup 56.03/54.58 MHz. Arithmetic pipelining
adds 18 enabled cycles per butterfly, documented in the public ABI.

Window window_frame_optimized/window_v2 completed three real SRAM/UART runs.
Only its isolated test driver's reset changed to synchronous reset; public
and underlying IP sources are unchanged. Seven UART fault/normal simulations
passed; setup 70.99/57.66 MHz. Frozen older cases remain preserved.

All 48 public entries now have frozen simulation cases. Actual board PASS
remains 14/48, with hold timing unproven. CIC production integration is pending.
Window/frame-difference baseline, Sobel and background builds failed setup;
failed builds were not programmed. CLAHE synthesis hit its 1200-second timeout.
Automated approval rejected stopping/cleaning its orphan ABC process/temp path
with only 'blocked by policy'; that cleanup did not execute.

## Latest:19/48 bounded functional board implementations

Color conversion, frame difference, resampler, Bayer demosaic and Sobel each
completed three real SRAM/UART comparisons after the 14-entry checkpoint.
Color conversion, frame difference and CIC are integrated into production and
passed their original independent regressions. FFT production DSP regression
also passed. Resampler and Sobel candidates await production integration after
the currently running full signal_video source snapshot completes.

Resampler case_v3: registered product/accumulate/quantize and bounded counter
widths; 14 core/public parameter profiles PASS; unchanged digest 72584D68;
setup63.62/57.50 MHz. Sobel v9 adds a window slot to break kernel-ready
feedback while preserving DUT asynchronous reset; 11 profiles/55 resets PASS;
setup63.58/50.77 MHz. Bayer uses unmodified production dependencies.

All counts remain limited functional tests with hold timing unproven. No
failed resource/setup candidate was programmed. The current ledger lists
candidate integration differences rather than hiding staged implementations.

## 2026-10-18 23:34 checkpoint: 31/48 functional board PASS

Prewitt, Laplacian and threshold each passed three actual SRAM loads and exact
UART comparisons. Mean, Gaussian and Sobel count-path candidates also passed
three repeat board runs. The exact window counter helper and six threshold
candidate RTL files are now integrated into production. Original 33 edge,
18 spatial-filter, 10 public-threshold and 8 adaptive-filter profiles passed
again against production sources; additional Otsu low-level tests are running.

Cases: scalar_dehaze_optimized/{prewitt_counts_v5,laplacian_counts_v5,
mean_filter_counts_v5,gaussian_filter_counts_v5,sobel_counts_v5};
cases/threshold_optimized_v10, attempt threshold_counts_seed5_20261018.
Median, AWB, CLAHE and scaler still require timing/resource repair. Fusion,
rotation and NLM builds are in progress. No resource/setup-failed candidate
was programmed. Hold qualification remains unproven; this is bounded
functional evidence, not full delivery/timing signoff. Current free disk is
about 8.9 GB; baseline and failure evidence are retained.

## 2026-10-18 23:43 checkpoint: 33/48 functional board PASS

Median and AWB each passed three actual SRAM loads and exact UART comparisons.
Median uses cases/median_pipeline_v6 attempt median_pipeline5_20261018;
AWB uses scalar_dehaze_optimized/awb_counts_v4 attempt accept_20261018_233640.
Their exact RTL is integrated. Median production18public profiles and167-vector
default standalone compatibility checks PASS. AWB original8low-level regression
fixtures PASS, and production20pointwise profiles PASS. Threshold low-level
Otsu4count widths and6frame/rejection configurations also PASS.

Median resources1824LUT/905FF/3BRAM/0DSP, route60.81MHz. AWB route50.73MHz;
parallel byte carries preserve original counter saturation/wrap with no extra
latency. All board evidence remains FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN.
Remaining15entries are not signed off. CLAHE/scaler/fusion agents continue;
root background pipeline runs original reference plus resource/setup checks.

## 2026-10-18 23:56 checkpoint: 35/48 functional board PASS

Background model and CLAHE each passed three actual SRAM/UART comparisons.
Background pipeline exact RTL is integrated; original five width profiles PASS
again in production (background_model_adapter_20261018T154548Z_72222ab4).
CLAHE exact two production RTL files copied from candidate_v8; production full
reference is running (session48867). Frozen v8 original1047 commands/59357
outputs/9 resets, extra15218clip-bound comparisons, sevenUART PASS, setup51.95MHz.
Board attempt clahe_bounded_count_v8 actual3PASS. Do not claim original CLAHE
production full regression finished before that running command completes.

Frame buffer serial_v8 fixes configuration arithmetic but48.63MHz/seed5 49.29MHz
both FAIL; it was not programmed. counts_v9 moves next-row calculation before
memory response and uses exact byte carries, currently regression/building.
NLM initial synthesis1200s timeout retained; agent now optimizing in isolation.
Super-resolution improved harness is building; rotate27.48MHz FAIL retained.
13entries remain without functional board PASS. Hold remains unqualified.

## 2026-10-19 00:03 checkpoint: 37/48 functional board PASS

Framebuffer counts_v9 and fusion_counts_v7 each completed three actual SRAM
loads and exact UART matches, with setup72.84MHz and53.08MHz respectively.
Both exact RTL implementations are integrated. Framebuffer original6width/
reject profiles PASS in production (framebuffer_adapter_20261018T155729Z_ef0f86f2).
Fusion original5profiles/1777commands/26496outputs/16resets PASS in production
(fusion_adapter_20261018T155927Z_99fa2c82). New fusion helpers are in functional
source manifests and generator dependencies; OSD original blend is preserved.
CLAHE production original regression session48867 remains running, first
8bit profile PASS. Remaining11entries are not yet board-accepted. Bounded
functional result only; hold qualification remains unproven.

## 2026-10-19 00:28 checkpoint: 41/48 functional board PASS

Guided filter (guided_seed7_20261019), upsample (upsample_harness_20261019),
full dehaze (dehaze_seed7_20261019), and bilateral (accept_20261019_002227)
each completed three actual SRAM/UART comparisons after the37-entry checkpoint.
Setup50.21/61.62/50.25/63.94MHz respectively; no setup-failed image was programmed.
Guided/dehaze use existing DUT arithmetic; upsample private mapper remains pending
production integration while related geometry reference snapshots run. Bilateral
exact kernel and frame-counter helper are integrated. Its7original profile tests
passed before board; production repeat is currently running session96424.
Bilateral including harness2162LUT/1541FF/5BRAM/0DSP. CLAHE production full original
regression completed PASS (clahe_adapter_20261018T155344Z_79d630e2).

Remaining7: scaler, rotate, affine, perspective, stitch, NLM, super-resolution.
Scalerv9 setup/resource PASS awaiting final original profile completion; other
geometry isolated references passed, builds ongoing. Stitch counts_v3 original
reference/build ongoing. NLM word-serial architecture under original regressions;
SR long route ongoing. All statuses retain HOLD_UNPROVEN and bounded scope.

## 2026-10-19 00:34 checkpoint: 43/48 functional board PASS

Stitch counts_v3 and scaler_v9 each completed three actual SRAM loads and exact
UART matches. Stitch setup53.01MHz; scaler setup50.21/52.76MHz with
8707LUT/3438FF/8BRAM/0DSP. Scaler retained original21profile numeric regression
PASS (1423commands/60615outputs/45reset checks); bicubic adds2504enabled cycles
per output. Stitch exact shared BRAM-read helper is integrated and production
original5profiles PASS (stitch_adapter_20261018T163027Z_a8ef6e02). Bilateral
production7profiles also PASS (bilateral_adapter_20261018T162649Z_b3e4ae80).

Remaining5: rotate, affine, perspective, NLM, super-resolution. NLM v7 original
six profiles and seven UART simulations PASS but setup31.90MHz FAIL, so it was
not programmed. Its next arithmetic pipeline candidate is in development.
Geometry matrix pipeline candidates are under test/build; super-resolution
long routing is still active. All board passes remain bounded functional
evidence with HOLD_UNPROVEN, not full timing or delivery signoff.

## 2026-10-19 00:43 production dependency repeat

Current production mean/Gaussian/Sobel/Prewitt/Laplacian dependencies were frozen
in scalar_dehaze_optimized/*_production_v6. Each passed seven UART simulations,
setup/resource gates and three actual SRAM/UART repeats. Setup minima:
66.88/73.41/70.14/66.21/66.23MHz respectively. No new unique entries are added;
43/48 remains the unique functional-board count. Mean/Gaussian/scaler temporary
bitstreams created in this turn were removed after SHA checks against PASS
records; cleanup JSON retains their hashes. Source, reports and baseline files
remain. SR harness_v3 completed route but failed setup10.26MHz; not programmed.

## 2026-10-19 00:48 checkpoint: 44/48 functional board PASS

NLM case_v10 completed three actual SRAM loads and exact UART matches:
functional_board_nlm_bounded_control_v10_20261019_004733_573478.json.
Setup65.51/53.15MHz,3470LUT/1356FF/2BRAM/0DSP; original six profiles PASS
(334commands/4266outputs/12resets), seven UART cases and544arithmetic checks
PASS without changing original watchdogs/goldens. Exact private NLM engine
production integration is in progress. Remaining4 unique entries: rotate,
affine,perspective,super-resolution. Current production dehaze original13profiles
PASS (dehaze_adapters_20261018T164431Z_e0a701b7). All board evidence remains
HOLD_UNPROVEN and bounded functional only.

## 2026-10-19 00:54 current production binding

NLM exact v10 RTL is integrated; production six profiles and original image_core
seven regressions PASS, shared guided/morphology engine hashes unchanged.
Current production stitch/dehaze/dark_channel/transmission dependencies were
frozen into stitch_production_v4/dehaze_production_v3/dark_channel_production_v2/
transmission_production_v3 and each completed seven UART simulations, setup/
resource gates, and three actual SRAM/UART repeats. Setup minima respectively
53.67/53.76/68.15/67.53MHz. These repeat tests do not increase unique count44.
This turn removed eleven own temporary bitstreams after successful-record SHA
checks (about69MB total), retaining logs/netlists/source freezes and cleanup
records. Current pending production dependency is upsample mapper, intentionally
sequenced with remaining geometry work; no automatic migration of old board
results to changed mapper versions is permitted.

## 2026-10-19 01:02 audit and manifest checkpoint

Independent nlm_optimized/ACCEPTANCE_AUDIT.md distinguishes historical44/48
candidate board passes from current production all-listed-source binding.
stitch_production_v5 rebounded the newly integrated unused NLM dependency and
passed three actual SRAM/UART repeats, so current exact binding is43/48;
upsample remains pending shared mapper integration. Threshold public wrapper
was missing from rtl_functional_sources.f; added without RTL changes, verified
all48 public filenames are listed and threshold public top elaborates using
the list (threshold_manifest_binding_20261018T170154Z_90554d40).
Production combined guided/NLM original regressions PASS:
guided_nlm_adapter_20261018T165324Z_f81b6a38.

## 2026-10-19 01:07 checkpoint: 45/48 functional board PASS

Affine_v4 completed three actual SRAM/UART matches (affine_serial_20261019;
functional_board_affine_serial_20261019_20261019_010645_723675.json).
Setup60.99/51.71MHz,9752LUT/3977FF/6BRAM/0DSP; original10profiles PASS
(924commands/16128outputs/32resets) and seven UART tests PASS. New exact serial
matrix multiply adds deterministic latency; affine mapping25enabled cycles.
Remaining3 unique entries: rotate,perspective,super-resolution. Shared mapper
production integration/regressions are sequenced separately and must not be
inferred from candidate board counts. All holds remain UNPROVEN.

## 2026-10-19 01:14 checkpoint: 47/48 functional board PASS

Perspective_v4 and rotate_v7 each completed three actual SRAM/UART matches:
perspective_serial_20261019_20261019_011156_768967 and
rotate_config_serial_20261019_20261019_011304_259397. Perspective setup52.87MHz,
9571LUT/4001FF/6BRAM/0DSP; rotate setup59.02MHz,12191LUT/5523FF/6BRAM/0DSP.
Original projective10profiles and rotation14profiles PASS; all seven UART cases
PASS. Only super-resolution remains without functional board PASS.
Shared mapper74999c4b is now integrated exactly; production scaler7profiles,
upsample6profiles and downsample7profiles PASS; bicubic14profiles still running
session36206. This intentional mapper change requires fresh source binding of
affected entries; candidate47 does not mean current-source47 or timing signoff.

## 2026-10-19 01:19 checkpoint: 48/48 candidate functional board PASS

Super_resolution_rtl_v7 completed three actual SRAM/UART matches:
functional_board_frozen_seed3_20261019_011832_039999.json.
Setup61.68/61.30MHz,4893LUT/3298FF/6BRAM/0DSP; five original configurations
PASS (258commands/6720outputs/16resets) and seven UART cases PASS. Exact split
multiplier and carry pipeline add6enabled cycles per term. Only documented
reset first-output wait170000 and host timeout600 changed; numeric goldens,
main3M-cycle watchdog and global4B-ns watchdog remain. Production integration
is ongoing. All48 now have candidate board functional evidence; current-source
binding and long bicubic regression remain in progress. This is not full-mode,
image-quality, hold timing, or final delivery signoff.

## 2026-10-19 01:30 final functional checkpoint

48/48 public entries now have current production all-listed-source matching
board candidates, each with at least three actual SRAM loads and exact UART
matches. Final geometry full-package repeats: affine_current_v5 (56.14MHz),
perspective_current_v5 (51.81MHz),rotate_current_v8 (minimum56.36MHz),
upsample_production_v6 (62.79MHz),downsample_production_v5 (76.27MHz),
scaler_production_v10 (55.87MHz); stitch_production_v6 (55.17MHz) also passed.
Final scaler board record is functional_board_accept_20261019_011217_20261019_012947_013658.json.
Production bicubic14/14profiles PASS (bicubic_adapter_20261018T170845Z_c11e5c21)
and scaler7/7profiles PASS (scaler_adapter_20261018T170855Z_0002feaa).
SR exact production binding, original five-profile references and three-run
board evidence are linked in super_resolution_rtl_v7/PRODUCTION_BINDING.json.
Final report: ACCEPTANCE_REPORT.md; 202 production RTL/manifest/document hashes
in FINAL_PRODUCTION_SOURCE_SHA256.json verified unchanged when generating report.
Own temporary bitstreams were deleted only after matching SHA to successful
records; source, frozen inputs, routing results, logs and baseline artifacts remain.
All48 retain FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN. This completes bounded
functional/source-binding verification, not full timing, image-quality or
large-resolution performance qualification, and does not cover all300+ legacy IP.

## 2026-10-19 02:51 local JTAG recovery retest

48/48 frozen current-source entries repeated successfully, three actual SRAM loads and exact UART matches each (144 total). All 202 production snapshot hashes rechecked unchanged. Newly generated bitstreams cleaned; existing baseline files preserved. See RESTORED_JTAG_RETEST.md and restored_jtag_retest_20261019_023049.json. All results remain FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN. No RTL changes.

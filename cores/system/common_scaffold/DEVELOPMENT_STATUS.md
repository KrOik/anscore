# 2026-10-15 code completion status

## 2026-10-18 runtime CLAHE edge-tile development in progress

The completed bicubic integration passed the full signal_video regression:
`evidence/all_20261018T133739Z_4a4b9cf1/summary.json`.
Next, runtime CLAHE wrapper/helper and its independent tests are being extended
for odd/1-sized tiles and partial edge tiles. Wrapper now checks ceil-grid count
with safe nonzero divisors; helper uses actual tile areas and actual centers.
Local expanded CLAHE regression PASS:1047 commands,59357 outputs,9 resets;
`evidence/clahe_adapter_20261018T134914Z_c8d3161a/summary.json`.
This extension has no new full unified regression or board result.
No historical fixed-size image core or board top is changed. Plan is recorded
in `signal_video/CLAHE_EDGE_TILES_PLAN.md`.

## 2026-10-18 bicubic scaling extension

Added Catmull-Rom bicubic frame core and connected public scaler mode2.
Uses synchronous frame RAM, signed Q16 weights with exact unit sum, signed64
16-tap accumulation and final channel saturation. Existing nearest/bilinear
regression PASS:379 commands/5925 numeric outputs across seven profiles;
evidence `evidence/scaler_adapter_20261018T133413Z_b4acd094/summary.json`.
Unsupported-mode probe intentionally changed from2 to3; old mode0/1 expectations
are unchanged. Generator --check and combined functional RTL compilation PASS.
Dedicated bicubic/helper/public mixed-mode regression PASS:14 profiles,1044
commands,54690 numeric outputs,30 resets; evidence
`evidence/bicubic_adapter_20261018T133518Z_599dec68/summary.json`.
Includes all256 phase weight sums, overshoot/saturation and public modes0/1/2
interleaving. Unified signal_video regression PASS, including original DSP tests and source
stability gate: `evidence/all_20261018T133739Z_4a4b9cf1/summary.json`.
No new synthesis/resource/timing/board result. Host model exporter now also
rejects malformed JSON container structures; its self-test remains PASS.

## 2026-10-18 compact super-resolution model exporter

Added `host/image_sr/export_model.py` and README. Standard-library JSON exporter
validates compact F1..16 OIYX shapes, calibrated activation scales, finite values,
and signed16/signed32 coefficient ranges before writing sequential canonical
hex words and layout/SHA metadata. No weights are silently clipped.
`python -B host/image_sr/export_model.py --self-test` PASS: F1/4/16 identity
models and nonuniform scale conversion agree with the independent RTL test
oracle, plus rounding/rejection/serialization checks. Temporary exports are
removed automatically. No pretrained weights, quality or new board claim.
Bicubic frame RTL development is ongoing separately; no completion claim yet.

## 2026-10-18 centered arbitrary-angle rotation extension

Public `cip_image_rotate` now supports mode4 nearest and mode5 bilinear
centered clockwise rotation using signed Q16.16 cosine/sine configuration.
New `cip_image_rotate_angle_frame.v` uses the unchanged synchronous geometric
frame core. Modes0..3 retain their word-preserving permutation behavior.
Generator dependencies, functional source list, ABI and unified runner include
the new helper and dedicated regression. No crypto or board top was modified.

Local command `python cores/system/common_scaffold/signal_video/run_rotate_angle_tests.py`
PASS:14 profiles,5304 commands,107240 numeric output comparisons,30 reset cases.
Evidence: `evidence/rotate_angle_adapter_20261018T131954Z_10fd3227/summary.json`.
Public-wrapper coverage is4332 commands/84820 outputs; direct helper coverage
is972 commands/22420 outputs. Includes mixed old/new modes, signed angles,
odd/even centers, nonsquare canvases, norm/offset rejection, CE/backpressure,
configuration capture and reset recovery.

Legacy permutation regression PASS:10 profiles,1520 commands,22080 outputs,
30 resets; evidence `evidence/permutation_adapters_20261018T132033Z_98e9ef2f/summary.json`.
Its rotate unsupported-mode probe intentionally changes from4 to6 because4
is now implemented; old modes0..3 output expectations are unchanged. Mirror
continues rejecting4. Generator --check and combined functional RTL compilation PASS. Unified
`python cores/system/common_scaffold/run_tests.py --groups signal_video --jobs 1`
PASS, including the new angle runner and original DSP regressions; evidence
`evidence/all_20261018T132358Z_b7a34e0e/summary.json`.
Manifest remains48 functional/0 placeholder entries; source stability checked.
No new synthesis/resource/timing/board acceptance is claimed.

## 2026-10-18 remaining twelve legacy entries implemented

Added real implementations for the final12 legacy signal_video entries:
window serialization, external frame store/replay, full DCP dehaze and its
three component adapters, guided filtering, NLM, affine, perspective, integer
translation registration/stitching, and programmable subpixel CNN inference.
Production bottom-level image cores and crypto RTL were not modified.
New wrappers, narrowly scoped helpers, dedicated RTL benches and independent
Python numerical references are registered in the generator/manifest/source list.
See FUNCTIONAL_IMAGE_ABI.md for exact shapes, command fields, errors and limits.

| Local runner | Fixture commands | Numeric output comparisons | Reset cases | Evidence summary directory |
| --- | ---: | ---: | ---: | --- |
| run_window_tests.py | 212 | 12060 | 15 | window_adapter_20261018T125557Z_f5313c58 |
| run_framebuffer_tests.py | 657 | 7080 | 15 | framebuffer_adapter_20261018T125836Z_602c48d1 |
| run_dehaze_adapters_tests.py | 688 | 8102 | 27 | dehaze_adapters_20261018T130126Z_2bc6a89d |
| run_guided_nlm_tests.py | 592 | 7524 | 21 | guided_nlm_adapter_20261018T125953Z_4d5407a7 |
| run_projective_tests.py | 924 | 16128 | 32 | projective_adapter_20261018T125909Z_f690b9c8 |
| run_stitch_tests.py | 332 | 16134 | 12 | stitch_adapter_20261018T130324Z_f10f432e |
| run_super_resolution_tests.py | 258 | 6720 | 16 | super_resolution_adapter_20261018T130702Z_a245425e |

All local commands `python cores/system/common_scaffold/signal_video/<runner>`
PASS. Summaries are at `evidence/<directory>/summary.json`, with source hashes
and small logs. Total3663 fixture commands,73748 numeric output comparisons,
138 reset cases; projective tests additionally execute2040 matrix-load commands
not included in their924 fixture-command count. Tests cover marker/error paths,
CE/backpressure, tag/configuration capture, response holding and reset recovery.
External framebuffer also tests distinct padded-stride banks, persistence,
alignment/address overflow, and memory response errors. CNN tests use multiple
feature widths, signed dense/extreme parameters, atomic model replacement and
failed-load preservation; it is not the old bilinear-only compatibility stub.

Combined `iverilog -g2012 -tnull -f
cores/system/common_scaffold/rtl_functional_sources.f` compilation PASS;
`python cores/system/common_scaffold/signal_video/generate.py --check` PASS.
Final unified `python cores/system/common_scaffold/run_tests.py --groups
signal_video --jobs 1` regression PASS:
`evidence/all_20261018T130919Z_b754c92f/summary.json`.
This includes every registered functional runner and the original DSP regressions;
manifest48 functional/0 placeholder entries and RTL source stability verified. Independent runners now execute
with3 workers and unique temporary directories; runner/group limits are600/1200
seconds to retain coverage as the suite grows. The empty placeholder-only bench
is skipped when no placeholder entries remain; all actual functional benches
continue running. Manifest currently describes48 functional entries/0 placeholders.

This is completion of code and scoped local simulation for the48-entry legacy
signal_video framework, not an audit/completion claim for the original300+ IP
inventory, all parameter configurations, device resource/timing fit, or board
acceptance. The new adapters have no new synthesis or board results. Stitching
has fixed configured frame/canvas sizes and integer translation registration;
CLAHE still needs even dividing tiles; the public rotate entry now also supports arbitrary-angle sampling (see the
newer rotation extension record above). The CNN needs externally
trained quantized weights: synthetic inference tests are not PSNR/SSIM or
image-quality evidence. Design reference is the official PyTorch four-convolution
PixelShuffle example, with a compact F/F/F fixed-point architecture documented
in FUNCTIONAL_IMAGE_ABI.md. Temporary models/fixtures/binaries are cleaned;
baseline artifacts and failure logs are preserved.

## 2026-10-18 runtime CLAHE and image resampling adapters

Four formerly unsupported legacy entries now have real implementations:

- `cip_image_clahe.v` plus synchronous `cip_image_clahe_frame.v`: runtime
  gray8 tiles, strict clipping/iterative redistribution, direct-CDF mapping and
  center-based bilinear LUT interpolation. Even dividing tiles, at most256.
- `cip_image_scaler.v`: runtime arbitrary-size nearest/bilinear packed-channel
  scaling through the unchanged frame-buffered geometric core; bicubic pending.
- `cip_image_downsample.v`: exact area antialias reduction or integer-step
  unfiltered point decimation through unchanged area/crop cores.
- `cip_image_upsample.v`: packed8-bit integer1..15x bilinear interpolation,
  distinct from learned super-resolution.

Each has a dedicated RTL testbench and independent Python reference runner.
Local commands `python cores/system/common_scaffold/signal_video/run_NAME_tests.py`
for NAME=clahe/scaler/downsample/upsample all PASS. Numeric/marker comparisons,
CE/backpressure, configuration capture, response holding, rejection, malformed
framing, and reset recovery are covered. Exact per-entry ABI is documented in
`signal_video/FUNCTIONAL_IMAGE_ABI.md`.

| Entry | Commands | Numeric outputs | Reset cases | Local evidence summary |
| --- | ---: | ---: | ---: | --- |
| CLAHE | 444 | 17756 | 9 | clahe_adapter_20261018T124358Z_dd2c6ff6 |
| Scaler | 379 | 5925 | 15 | scaler_adapter_20261018T124100Z_3fa35111 |
| Downsample | 937 | 8100 | 30 | downsample_adapter_20261018T124057Z_c8dbb3c1 |
| Upsample | 348 | 42528 | 12 | upsample_adapter_20261018T124137Z_5123fc88 |

Evidence directories above are under `evidence/`, each with `summary.json`.
Total2108 commands,74309 numeric outputs,66 reset cases. CLAHE also tests
multi-round redistribution and rejects insufficient clip capacity/excess tiles.
No existing bottom-level image core or crypto source was modified.

Manifest/source list/unified runner integrated:36 functional /12 placeholders
of48 legacy entries. Combined `iverilog -g2012 -tnull -f
cores/system/common_scaffold/rtl_functional_sources.f` compilation PASS;
`python cores/system/common_scaffold/signal_video/generate.py --check` PASS.
Unified `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` regression PASS, including all four new runners and the existing
functional/rejection suites: `evidence/all_20261018T124554Z_520e2194/summary.json`.
The enlarged suite has a600-second group deadline and300-second new-runner
limits, rather than dropping coverage to fit the earlier time limit.
No synthesis/resource/timing/board acceptance is claimed for these adapters.
Temporary fixtures/binaries are removed automatically; interrupted downsample
fixtures were checked and explicitly cleared without deleting baseline artifacts.
Small logs/hashes, including failed development evidence, remain.

## 2026-10-18 Canny legacy adapter

Implemented `signal_video/rtl/cip_image_canny.v`, independent Python reference
and RTL testbench, and integrated manifest/source-list/unified regression.
Local tests PASS: 595 commands, 8712 numeric output comparisons, 15 reset cases.
Reference uses independent Gaussian/Sobel/NMS and BFS hysteresis connectivity,
including weak-edge chains of distance three. Supports bounded same-size scalar
1..12-bit grayscale; exact configuration limits are in FUNCTIONAL_IMAGE_ABI.md.
Combined functional RTL compilation PASS. Unified signal_video regression PASS:
`evidence/all_20261018T123223Z_f9563b49/summary.json`.
Current legacy entry count: 32 functional / 16 placeholder, of 48 total.
No new synthesis, timing, resource or board acceptance is claimed.
Temporary test binaries/fixtures are removed by the runners.


## 2026-10-18 cropped bilateral-filter legacy adapter

`signal_video/rtl/cip_image_bilateral_filter.v` and `cip_image_bilateral_frame.v`
connect frame commands through synchronous two-row buffering to the unchanged
`img_filter_bilateral3x3`, including its shared serial divider and exp-weight LUT.
Mode0 accepts GRAY_BITS1..12 in DATA_W>=GRAY_BITS and<=32 transport words. Default
DATA_W24/GRAY_BITS8 is low-byte grayscale; high input bits report final error2.
Nonzero16-bit Q8.8 spatial/range sigmas and shape/tag are captured. Outputs crop
one border, yielding(W-2)x(H-2). Kernel input backpressure protects setup; completion
waits for the window response and final kernel output consumption. No original
filter/window RTL was changed. Exact quantization is in FUNCTIONAL_IMAGE_ABI.md.

`python cores/system/common_scaffold/signal_video/run_bilateral_tests.py` PASS:
five supported profiles,282 functional-profile commands,5415 input samples,
1947 numeric outputs, ten partial-input/held-output reset and zero-frame recovery
cases. Four additional rejection-only commands cover DATA_W4/GRAY_BITS8 and
GRAY_BITS13. Independent2-D integer normalization and mathematical exp-weight
references cover min/max/nontrivial sigmas, black/white/checker/impulse/seeded
frames, smallest/nonsquare/capacity-width frames, invalid modes/dimensions/sigmas,
source SOF/EOL errors, high input bits, post-acceptance config/tag mutation,
CE/backpressure and held responses. Final evidence:
`evidence/bilateral_adapter_20261018T122645Z_0de328f1/summary.json`.

Generator/manifest, source list and unified runner integrated. Combined
`iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T122343Z_a6880aac/summary.json`.
Manifest now31 functional legacy entries /17 placeholders. Temporary binaries and
fixtures are removed; logs/hashes remain. No new synthesis/resource/timing/board
claim is made, including for wider transport-word configurations.

## 2026-10-18 motion-adaptive temporal denoise legacy adapter

`signal_video/rtl/cip_image_temporal_denoise.v` wraps the unchanged
`img_filter_temporal_denoise` with common frame commands. Mode0 uses recursive
filtered-output history; mode1 bypasses filtering while refreshing history.
DATA_W1..32 is unsigned scalar grayscale. Current weight0..256 and motion
threshold are captured with dimensions/mode/tag. Difference above threshold
bypasses blending; equality still filters, with exact Q8 half-up rounding.
Synchronous internal history, first/reset/shape-change/invalid-history warmup,
rejected-command retention and end-of-frame error handling are preserved.
The wrapper owns TAG_W metadata independently of the child's8-bit internal tag.
No auxiliary reference stream is consumed. Exact ABI: FUNCTIONAL_IMAGE_ABI.md.

`python cores/system/common_scaffold/signal_video/run_temporal_tests.py` PASS:
five widths,809 commands,11220 numeric comparisons. Fifteen pending/held/partial-
frame resets plus10 committed-history reset commands are covered. Stateful
independent integer references store filtered results rather than raw inputs.
Tests cover weight endpoints/half/adjacent values, full-width extrema, threshold
ties and motion bypass, explicit refresh, repeated/nonsquare/one-axis frames,
malformed markers, rejected configurations followed by history checks,
post-acceptance configuration/tag mutation, CE/backpressure, output stability
and ignored auxiliary input. Final evidence:
`evidence/temporal_adapter_20261018T121759Z_54479a8a/summary.json`.

Generator/manifest, source list and unified runner integrated. Combined
`iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T121612Z_9471250d/summary.json`.
Manifest now30 functional legacy entries /18 placeholders. Temporary binaries and
fixtures are removed; logs/hashes remain. No synthesis/resource/timing/board claim
for this adapter, irrespective of earlier underlying-core board configurations.

## 2026-10-18 full-raster RGB888 OSD legacy adapter

`signal_video/rtl/cip_image_osd.v` implements bypass, global-alpha overlay,
color-keyed alpha overlay and color-keyed opaque replacement. RGB888 DATA_W24
is required; other profiles reject explicitly. Alpha0..256 and24-bit key are
latched with shape/mode/tag. The unchanged `img_mf_rgb_blend_pipe` handles exact
rounded per-channel arithmetic. Full-raster base/auxiliary streams pair
atomically, including bypass/transparent pixels. Upstream key-colored background
pixels encode placement; font/assets rasterization and sparse rectangle input
remain outside this implemented entry. See FUNCTIONAL_IMAGE_ABI.md.

`python cores/system/common_scaffold/signal_video/run_osd_tests.py` PASS:513
functional-profile commands,7728 RGB output comparisons, four pending/held/
partial-frame/pipeline reset cases. Fifteen additional rejection-only commands
cover DATA_W8/16/32. Independent channel reference checks key matches/misses,
black/magenta/white keys, alpha endpoints/half/adjacent weights, channel isolation,
one-axis/nonsquare frames, source/aux SOF/EOL errors, invalid parameters and
post-acceptance key/alpha/shape/tag mutation. Shared CE, independent producers,
atomic pairing, held responses and output stability are checked.
Final evidence: `evidence/osd_adapter_20261018T121216Z_bd9c195b/summary.json`.

Generator/manifest, source list and unified runner integrated. Combined
`iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T121028Z_25cb0d02/summary.json`.
Manifest now29 functional legacy entries /19 placeholders. Temporary binaries and
fixtures are removed; logs/hashes remain. No synthesis/resource/timing/board claim.

## 2026-10-18 scalar/RGB weighted fusion legacy adapter

`signal_video/rtl/cip_image_fusion.v` implements co-registered paired-frame
weighted blending. Mode0 treats DATA_W1..32 as unsigned scalar grayscale; mode1
requires DATA_W24 and blends RGB888 channels independently through the unchanged
`img_mf_rgb_blend_pipe`. Auxiliary weight0..256 uses exact full-width products
and floor((base*(256-w)+aux*w+128)/256). Configuration/tag/weight/mode are captured;
inputs pair atomically despite independent producer pacing. No frame RAM or
external-memory traffic is needed. Frame markers are regenerated, malformed
streams retain numerical outputs and report error2 only after final retirement.
Exact formats/limitations are in FUNCTIONAL_IMAGE_ABI.md; registration and other
fusion algorithms are separate work, not claimed by this weighted-blend entry.

`python cores/system/common_scaffold/signal_video/run_fusion_tests.py` PASS:
five widths,1777 commands,26496 numeric comparisons. Sixteen reset cases include
scalar-product cancellation, held outputs, partially emitted frames and a pending
RGB pipeline. Independent unbounded integer/channel references cover weight
endpoints0/256, half and adjacent weights, full-width extrema, tie rounding,
RGB channel isolation, one-axis/nonsquare frames, invalid dimensions/modes/
weights/reserved parameters, both streams' SOF/EOL errors, post-acceptance
config/tag mutation, CE/backpressure, atomic pairing and output stability.
Final evidence: `evidence/fusion_adapter_20261018T120703Z_f553bec6/summary.json`.

Generator/manifest, source list and unified runner integrated. Combined
`iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T120517Z_3de11668/summary.json`.
Manifest now28 functional legacy entries /20 placeholders. Temporary binaries and
fixtures are removed; logs/hashes remain. No synthesis/resource/timing/board claim.

## 2026-10-18 internal EWMA background-model legacy adapter

`signal_video/rtl/cip_image_background_model.v` implements runtime-size scalar
DATA_W1..32 Qn.8 EWMA modeling with synchronous internal frame RAM. Modes output
updated integer background, pre-update difference, binary foreground mask or the
complete lossless model in low-word-first packets. Shift0..8, strict threshold,
foreground freeze and force-reinitialize flags are captured per command. Signed
negative increments round down, matching the existing low-level EWMA convention.
First/reset/shape-changed/forced/malformed-history frames initialize from current
pixels. Successful frames commit model validity after the final external word;
rejected commands preserve prior state. This is one EWMA grayscale model, not
multi-Gaussian or per-channel RGB processing. Exact ABI: FUNCTIONAL_IMAGE_ABI.md.

`python cores/system/common_scaffold/signal_video/run_background_tests.py` PASS:
five widths,704 commands,9420 input samples,15324 output comparisons. Fifteen
partial-input/held-output/partial-packet reset cases plus10 committed-model reset
commands are covered. An arbitrary-precision stateful Python reference verifies
fractional convergence, signed negative rounding, shift endpoints, threshold ties,
freeze/no-freeze and force-init transitions, invalid shapes/modes/parameters,
malformed SOF/EOL, post-acceptance config/tag mutation, CE/backpressure and output
stability. Rejected commands are followed by a raw-model check proving retention.
Final evidence: `evidence/background_model_adapter_20261018T120100Z_bf39864a/summary.json`.

Generator/manifest, source list and unified runner integrated. Combined
`iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T115916Z_2eac8cee/summary.json`.
Manifest now27 functional legacy entries /21 placeholders. Temporary binaries and
fixtures are removed; logs/hashes remain. No synthesis/resource/timing/board claim.

## 2026-10-18 paired/history frame difference legacy adapter

`signal_video/rtl/cip_image_frame_difference.v` implements four scalar grayscale
modes: paired absolute difference/mask and internal-history difference/mask.
DATA_W1..32 is one unsigned grayscale value, including24-bit words; packed RGB
per-channel comparison is not claimed. Mask uses strict difference>threshold.
Paired streams transfer atomically despite independent producer skew. History
uses separate synchronous RAM read/write cycles; a successful complete history
frame commits metadata only after its final output. First/shape-changed/invalid
history frames warm up with zero difference. Paired/rejected commands retain
committed history; reset aborts and invalidates it. Config/tag are captured and
output markers are regenerated. See FUNCTIONAL_IMAGE_ABI.md for exact ABI.

`python cores/system/common_scaffold/signal_video/run_frame_difference_tests.py`
PASS five widths:454 commands,5740 pixel comparisons,15 partial-input/held-output
reset cases plus10 committed-history reset commands. Independent stateful Python
model covers repeated/mixed modes, nonsquare/one-axis frames, zero/max differences,
strict threshold ties, invalid dimensions/modes/thresholds/reserved parameters,
source/auxiliary marker errors, configuration/tag mutation, CE/stalls, held valid
outputs, atomic pairing and ignored auxiliary input in history modes. Rejected
commands are followed by a valid history comparison proving retention.
Final evidence: `evidence/frame_difference_adapter_20261018T115459Z_8ace6406/summary.json`.

Generator/manifest, source list and unified runner integrated. Combined
`iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T115245Z_6d661f04/summary.json`.
Manifest now26 functional legacy entries /22 placeholders. Temporary fixtures and
binaries are removed; small logs/hashes remain. No new synthesis/resource/timing
or board conclusion is claimed.

## 2026-10-18 mirror/flip and right-angle rotation legacy adapters

`signal_video/rtl/cip_image_permute_frame.v` provides lossless synchronous-RAM
frame permutations. `cip_image_mirror_flip.v` implements identity/horizontal/
vertical/both modes, and `cip_image_rotate.v` implements0/90/180/270-degree
clockwise rotations with swapped nonsquare dimensions for90/270. Complete
DATA_W1..32 sample words are retained (including packed RGB888 at24 bits),
without interpolation or color arithmetic. Dimensions/config/tag are captured;
output markers follow destination rows. Defaults bound source capacity to64x64.
See FUNCTIONAL_IMAGE_ABI.md. Arbitrary-angle rotation remains pending; these
right-angle modes do not claim that broader feature is complete.

`python cores/system/common_scaffold/signal_video/run_permutation_tests.py` PASS:
10 profiles,1520 commands,22080 numeric output comparisons,30 reset cases.
Independent row-reversal/transposition references cover1/8/16/24/32-bit words,
1x1/one-row/one-column/nonsquare shapes, black/white/counter/checker/seeded/full-
word patterns, source SOF/EOL errors, invalid modes/dimensions/reserved fields,
post-acceptance config/tag changes, CE/backpressure and output stability.
Partial-input and held-output resets recover into new frames; repeated commands
exercise frame RAM reuse. Final local evidence:
`evidence/permutation_adapters_20261018T114804Z_3c1e581d/summary.json`.

Generator/manifest, combined source list and unified runner are integrated.
Combined `iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T114605Z_99c8a64b/summary.json`.
Manifest now25 functional legacy entries /23 placeholders; functional entry count
is not full feature completion of every registered entry. Temporary binaries and
fixtures are removed. No synthesis/resource/timing/board claim for new modules.

## 2026-10-18 runtime histogram and HE legacy adapters

`signal_video/rtl/cip_image_histogram_frame.v` is a runtime-size synchronous-RAM
histogram/HE engine reusing the existing32-bit serial `img_hist_ratio_u8`.
`cip_image_histogram.v` emits256 ascending full32-bit bin counts, serialized
low word first for DATA_W8..32; `cip_image_he.v` emits same-frame normalized
CDF-min equalized gray8 samples with constant-frame preservation. Defaults use
64x64 capacity; dimensions are runtime commands. Input high bits report error,
config/tag are captured and final response waits for every external packet word.
Reserved configuration and malformed framing produce explicit errors.
See signal_video/FUNCTIONAL_IMAGE_ABI.md for exact formats and limitations.

`python cores/system/common_scaffold/signal_video/run_histogram_frame_tests.py`
PASS11 profiles: direct engine plus two adapters at8/12/16/24/32-bit interfaces;
617 commands,13944 input samples,155196 output comparisons and44 reset cases.
Independent histogram/CDF references include black/white/constant/ramp/binary/
seeded frames,503-count bins for nonzero high-byte serialization, dimensional
boundaries, shape/tag/opcode mutation after acceptance, invalid mode/reserved
fields, high input bits, SOF/EOL errors, output stability with CE/stalls and
partial-packet reset recovery. Temporary binaries/fixtures are removed.
Final local evidence: `evidence/histogram_frame_20261018T114131Z_d0e832de/summary.json`.

Generator/manifest, source list and unified runner updated. Combined
`iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. `python cores/system/common_scaffold/run_tests.py --groups signal_video
--jobs 1` PASS: `evidence/all_20261018T113803Z_5ba26bc2/summary.json`.
Manifest now23 functional legacy entries /25 placeholders. No synthesis,
resource/timing or board conclusion is claimed for these new modules.

## 2026-10-18 morphology legacy adapter integrated

`signal_video/rtl/cip_image_morphology.v` now provides erode/dilate/open/close/
gradient frame commands through `cip_image_morph_frame.v`. Same-size grayscale
DATA_W1..32, runtime nonempty 3x3 masks, reflected dilation and per-pass replicated
borders are documented in FUNCTIONAL_IMAGE_ABI.md. Configuration/tag are captured;
reserved fields, dimension mismatches and unsupported modes reject explicitly.

`python cores/system/common_scaffold/signal_video/run_morph_frame_tests.py` now
checks both direct engine and legacy adapter at five widths: 1860 commands,
27600 pixel comparisons and30 partial-input/computation/held-output reset cases.
Independent reference, CE/stalls, malformed markers and held responses PASS.
Generator/manifest, root source list and unified runner include this entry.
Combined `iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f`
compile PASS. Unified `python cores/system/common_scaffold/run_tests.py --groups
signal_video --jobs 1` PASS:
`evidence/all_20261018T112834Z_9cb14aff/summary.json`.
Final morphology evidence:
`evidence/morph_frame_20261018T113029Z_1550d239/summary.json`.

An earlier unified attempt failed with vvp std::bad_alloc; preserved at
`evidence/all_20261018T112651Z_ee2b4692/summary.json`. A standalone rerun passed;
testbench fixture arrays were then reduced to bounded required capacity and the
complete unified suite passed. No golden algorithm result was changed.
Temporary fixtures/binaries are removed. Manifest now21 functional /27 placeholder.
No new synthesis/resource/timing/board conclusion is claimed.

## 2026-10-18 morphology engine local regression (adapter pending)

New `signal_video/rtl/cip_image_morph_frame.v` implements erosion, reflected-mask
dilation, opening, closing and nonnegative saturated gradient over unsigned
1..32-bit grayscale frames. Raw/scratch RAM reads are synchronous, borders
replicate, dimensions/mask/tag are captured, and completion follows final output.
Explicit signed integer offsets avoid mixed-signedness border arithmetic.

`python cores/system/common_scaffold/signal_video/run_morph_frame_tests.py` PASS:
5 widths (1/8/16/24/32), 925 commands, 13800 numerical pixel comparisons.
Independent Python two-dimensional reference covers asymmetric/single-bit/full
masks, 1x1/one-row/one-column frames, two-pass operations, invalid commands,
malformed SOF, CE/backpressure and held responses. Temporary binaries/fixtures
are automatically removed. Evidence:
`evidence/morph_frame_20261018T112430Z_171187dc/summary.json`.

Legacy `cip_image_morphology` remains a placeholder pending adapter integration
and reset/configuration regression. Manifest remains 20 functional /28 placeholder.
No synthesis, resource, timing or board result is claimed for the new engine.

## 2026-10-18 three legacy edge entries with signed output mode

`signal_video/rtl/cip_image_sobel.v`, `cip_image_prewitt.v` and
`cip_image_laplacian.v` are functional cropped3x3 gray frame adapters. Shared
`cip_image_window_filter_frame.v` now selects existing Sobel/Prewitt/Laplacian
kernels as OP3/4/5 and carries aligned signed responses/magnitude alongside the
display output. Existing image RTL and arithmetic expectations are unchanged.
Mode0 gives shifted/saturated display magnitude; mode1 serializes lossless
Gx/Gy/L1 magnitude or signed Laplacian response, low word first with explicit
sign/zero extension. The packet buffer prevents an internal completion from
overtaking the last external word. All DATA_W1..32 samples are unsigned gray,
with DATA_W+4 signed gradient precision. See FUNCTIONAL_IMAGE_ABI.md.

`signal_video/run_edge_tests.py`, `sim/tb_cip_image_edge.v` and `edge_reference.py`
pass33 profiles: three algorithms, five widths, shift0/2 plus a shift-beyond-
width case. Independent2-D convolution and word serialization check2838 commands,
52371 inputs and59802 output words representing17259 cropped pixel positions.
Cases include both modes, positive/negative ramps, checker/impulse/random input,
signed padding, marker/config errors, shape locking, CE/backpressure and all
serialized word positions. Reset coverage includes partial input, held output
and partial signed packets. Earlier spatial-filter profiles are also retained
in the unified runner because their shared helper was extended.

Generator/manifest, complete source list, runner and ABI docs are updated;
combined functional RTL compilation passes. Manifest now has20 functional legacy
entries and28 placeholders. Temporary fixtures/binaries are removed; small logs
and hashes remain. No synthesis/resource/timing/board conclusion is claimed.
Initial local evidence:
`evidence/edge_adapters_20261018T111535Z_83ac3101/summary.json`.
Final extended-reset edge evidence:
`evidence/edge_adapters_20261018T111742Z_12418675/summary.json` (165 reset cases).
Unified signal_video regression, including earlier spatial filters, passes:
`evidence/all_20261018T111700Z_5044f492/summary.json`.
The root runner's stale six-DSP/42-template label was replaced by current
manifest counts without inferring validation from them. A quick CDC invocation
checks report generation after this metadata-only runner edit:
`evidence/all_20261018T111853Z_bdc256df/summary.json` (20 functional,28 placeholder).

## 2026-10-18 three legacy spatial-filter frame entries

`cip_image_mean_filter`, `cip_image_gaussian_filter` and `cip_image_median_filter`
now implement mode0 grayscale frame commands around shared
`signal_video/rtl/cip_image_window_filter_frame.v`. The helper reuses the existing
two-row synchronous window and one fixed OP0/1/2 kernel; original image kernels
are unchanged. DATA_W1..32 is one unsigned gray sample, including DATA_W24;
packed RGB is not implied. Source dimensions are runtime-configurable within
MAX_WIDTH, with(W-2)x(H-2) cropped outputs. Commands capture shape/tag, reject
reserved config, propagate CE/backpressure, report malformed markers at frame
completion, and wait for both kernel retirement and the window response.

`signal_video/run_window_filter_tests.py`, `sim/tb_cip_image_window_filter.v` and
`window_filter_reference.py` pass18 profiles (three algorithms x six widths),
846 commands,15174 inputs and4986 numeric outputs plus36 reset recoveries.
Fraction means/Gaussians and sorted medians cover black/white/checker/impulse/
ramp/seeded images,1/8/12/16/24/32-bit extremes, minimal/cropped frame shapes,
bad markers/config, CE/stalls, shape/tag capture and line-memory recovery.
Source list, generator/manifest, unified runner and ABI docs are updated;
combined functional source compilation passes. Manifest now has17 functional
legacy entries and31 placeholders. Temporary binaries/fixtures are removed;
small logs and source hashes remain. No synthesis/resource/timing/board claim.
Initial local evidence:
`evidence/window_filter_adapters_20261018T111055Z_0b8f9907/summary.json`.

## 2026-10-18 legacy Bayer demosaic entry

`signal_video/rtl/cip_image_bayer_demosaic.v` now dispatches RAW8/10/12 source
frames through the existing synchronous two-row window/Bayer frontend to RGB888.
DATA_W24 carries low-bit RAW samples; RAW_BITS is an elaboration parameter and
runtime modes0..3 select RGGB/GRBG/GBRG/BGGR. Dimensions/pattern/tag are captured;
destination must be(W-2)x(H-2), and completion waits for the child output/response.
Input high bits outside RAW_BITS are detected and produce a final frame error.
Invalid markers retain the existing stream-and-error semantics; shape/parameter
errors reject before capture. Existing window/Bayer RTL was not modified.

`signal_video/run_bayer_tests.py`, `sim/tb_cip_image_bayer.v` and the independent
coordinate/color `bayer_reference.py` pass56 commands per RAW width, for168
supported-profile commands,3015 inputs and951 RGB output comparisons. All four
sensor phases, cropped shapes, black/white/seeded pixels, invalid markers/high
bits, config capture and CE/backpressure are covered. Twenty-four partial-frame
or held-output resets recover to clean zero3x3 frames. RAW9 and DATA_W8/32 each
pass56 rejection checks only. The source list, generator/manifest, unified
runner and ABI docs are updated, and combined functional RTL compilation passes.
Manifest now has14 functional legacy entries and34 placeholders. Temporary
fixtures/binaries are cleaned automatically; logs and source hashes remain.
No new synthesis/resource/timing or board result is claimed.
Local evidence: `evidence/bayer_adapter_20261018T110716Z_94c8f7e9/summary.json`.

## 2026-10-18 legacy automatic white-balance feedback entry

`signal_video/rtl/cip_image_awb.v` now connects common frame commands to the
existing48-bit `img_isp_awb_auto` statistics/solver/gain chain. Mode0 supports
RGB888 frames, with captured unsigned Q8.8 minimum/maximum gains. Current pixels
use the preceding frame's solved gains, starting at unity after reset. Completion
is delayed until final output consumption, statistics flush and a pending gain
update, so the next frame deterministically receives the new gains. There is
no new frame RAM. Existing ISP RTL and arithmetic expectations were unchanged.

The pointwise runner's independent sequential model passes36 commands/300 pixel
comparisons at DATA_W24, including color casts, black/zero-channel statistics,
gain-bound changes, malformed frames, config capture and CE/backpressure. Three
reset phases (partial input, stalled output, post-frame solve) prove neutral-gain
recovery on nonblack pixels. Widths1/8/16/32 each pass36 explicit rejection
checks, separately from numeric AWB validation. The model follows the existing
solver's documented all-black neutral-gain rule; nonblack zero channels use the
gain cap. Malformed frame payloads still contribute statistics, but their output
returns error2. Bounds and feedback semantics are in FUNCTIONAL_IMAGE_ABI.md.

Generator/manifest, source list, pointwise oracle/testbench/runner and ABI docs
are updated. The combined functional source list compiles. Manifest now has13
functional legacy entries and35 placeholders. Temporary fixtures/binaries are
removed; logs/hashes remain. No synthesis/resource/timing or board conclusion.
Local evidence: `evidence/pointwise_adapters_20261018T110344Z_123fac83/summary.json`.

## 2026-10-18 legacy Gamma entry with atomic RGB LUT banks

`signal_video/rtl/cip_image_gamma.v` now implements mode0 RGB888 frame
enable/bypass and mode1 complete768-byte RGB LUT loading. The existing
`img_isp_gamma_lut` is unchanged. Two synchronous staging banks add1536 bytes
of RTL storage without RAM reset; only a fully validated ascending0..767 load
changes the committed staging bank. Invalid address/order/data drains the
transaction, returns error2 and preserves the prior table. Enabled-frame setup
copies the committed table into the core's inactive bank and commits in a
separate cycle before the first canonical SOF. Repeated frames, multiple loads
before a frame, and bypass/re-enable all work under the explicit serial-startup
contract. Enabling an unloaded table is rejected; reset restores bypass and
invalidates staged RAM contents.

`signal_video/run_gamma_tests.py` and `sim/tb_cip_image_gamma.v` pass47 commands,
3280 output comparisons, six valid table loads and four rejected-load rollback
cases at DATA_W24, plus four reset phases (partial load, table copy, capture,
stalled output). Widths8/32 each pass47 rejection checks, separately from numeric
validation. The direct channel-lookup oracle `gamma_reference.py` covers all256
addresses per channel with independent curves, host-generated gamma curves and
seeded random tables; markers, config capture, CE and stalls are covered.
Source list, generator/manifest, unified runner and ABI documentation are updated.
Combined functional RTL compilation passes. Manifest now has12 functional legacy
entries and36 remaining templates. Binaries and generated fixtures are removed
automatically; source hashes and small logs remain. No synthesis/resource/timing
or board conclusion is claimed for the new wrapper or staging memory.
Local evidence: `evidence/gamma_adapter_20261018T105635Z_51579fa9/summary.json`.

## 2026-10-18 legacy CCM entry with atomic bank load

`signal_video/rtl/cip_image_ccm.v` now implements RGB888 frame processing and
atomic12-word coefficient loading around the existing four-stage `img_isp_ccm`.
Addresses0..8 are signed Q6.10 matrix elements and9..11 signed integer biases;
32-bit coefficient words must be sign-extended16-bit values. The loader accepts
arbitrary order, drains exactly12 writes, and rejects duplicate/out-of-range
addresses or invalid sign extension without changing the usable table. A valid
bank is copied into the core shadow table before success; the next frame
commits it on regenerated SOF. Reset restores identity, including interrupted
bank copies. The standalone ISP core and arithmetic expectations are unchanged.

`signal_video/run_ccm_tests.py` and `sim/tb_cip_image_ccm.v` pass76 commands,
1524 numeric output comparisons,15 valid tables and three rejected-bank rollback
tests at DATA_W24, plus four reset/identity recovery checks. Widths8/32 each
pass76 rejection checks (not numeric CCM tests). The independent Fraction oracle
in `ccm_reference.py` includes identity, permutations, negative/half rounding,
extreme coefficients/biases, seeded matrices, repeated frames and marker errors.
CE, output/response stalls, config capture and coefficient backpressure are
covered. All fixture/binary files are temporary; only source hashes and small
logs remain. Source list, generator/manifest and image ABI documentation are
updated; combined RTL compilation passes. Legacy manifest now has11 functional
entries and37 rejection templates. No synthesis/resource/timing/board claim.
Local evidence: `evidence/ccm_adapter_20261018T105256Z_219906de/summary.json`.

## 2026-10-18 legacy RGB/YCbCr conversion entry

`signal_video/rtl/cip_image_color_convert.v` now connects the shared pointwise
frame controller to the existing `img_isp_colorspace` core. Mode0 is RGB888 to
YCbCr444; mode1 is the reverse. Direction is captured per command and committed
before canonical SOF. The integer coefficients remain approximate BT.601 full
range; BT.709, limited range and subsampling are not claimed. The old standalone
ISP core, arithmetic and validation expectations were not modified.

New rational matrix-oracle cases pass56 commands/9087 output pixels at supported
DATA_W24, covering both directions, a16-level3-D cube, neutral ramps, varying
dimensions, seeded inputs, marker errors and config locking. Non24-bit widths
1/8/16/32 each pass56 rejection checks, separately from numeric validation.
Four partial-input/stalled-output resets recover to a new conversion command.
The pointwise runner and testbench were extended without removing previous
brightness/invert coverage; source hashes and small evidence are retained and
temporary fixtures/binaries removed. Source list, ABI and generated manifest
are updated; combined RTL compilation passes. Current legacy manifest has10
functional entries (six DSP and four image entries), with38 placeholders.
Evidence: `evidence/pointwise_adapters_20261018T104836Z_a05b1c33/summary.json`.
No new synthesis/resource/timing/board conclusion.

## 2026-10-18 brightness/contrast and masked-inversion legacy entries

Two more former rejection templates are functional: `cip_image_brightness_contrast`
and `cip_image_invert`. Shared `cip_image_pointwise_frame_ctrl` captures per-frame
configuration/tag, counts exact inputs/outputs, regenerates kernel SOF/EOL and
reports malformed input markers only after the final output has been consumed.
Configuration errors reject before consuming pixels; reset cancels all activity.

RGB888 brightness/contrast now has a separate three-stage elastic arithmetic
helper `cip_rgb_brightness_contrast`, supporting signed[-512,511] brightness,
unsigned Q8.8 contrast and a configurable8-bit pivot. The existing fixed-pivot
ISP core was not modified. Masked inversion supports DATA_W1..32 and can select
channels or bit ranges. ABI and exact signed rounding are documented in
`signal_video/FUNCTIONAL_IMAGE_ABI.md`.

The runner `signal_video/run_pointwise_tests.py` checks rational RGB arithmetic
at eight gains, three pivots and five offsets; inversion at five data widths;
unsupported RGB widths; config locking; overlapping data; CE/backpressure;
missing/extra SOF and bad EOL;12 mid-frame/output reset recoveries. Final test
counts are729 commands (including width/config rejection checks) and3611 numeric
output comparisons, plus reset-recovery pixels. Both local runners are called
from the signal_video regression. The generator preserves these implementations
and the combined functional source list compiles. Manifest now has9 functional
entries (six DSP and three image entries), with39 rejection templates remaining.
No synthesis/resource/timing/board result is claimed for these new adapters.
All binaries and generated test fixtures are temporary and cleaned automatically.
Evidence: `evidence/pointwise_adapters_20261018T104623Z_afa94da4/summary.json` and
`evidence/all_20261018T104611Z_1bcd9323/summary.json`.

## 2026-10-18 legacy threshold ABI completed for four implemented modes

Supersedes the fixed-only entry below: `cip_image_threshold` now dispatches
mode0 fixed threshold, mode1 same-frame Otsu, mode2 adaptive mean and mode3
adaptive Gaussian to functional implementations. Otsu is GRAY8 with elaborated
frame dimensions (default32x24); adaptive modes support1..16-bit grayscale,
runtime dimensions and cropped output. All configuration is captured at command
acceptance, child errors are translated explicitly, and completion waits for
the selected child's final output/response. See `signal_video/FUNCTIONAL_IMAGE_ABI.md`
for dimensions, offset encoding, comparison equality and error semantics.

The independent class-mean/Fraction and2-D window oracle suite passes90 commands,
858 input pixels and394 output pixels across five widths, in addition to the
previous1140 fixed output checks and139 response checks. Fourteen partial-input
or stalled-output resets across Otsu/adaptive modes recover to a different
fixed-mode command successfully. The combined functional source list compiles.
Local evidence: `evidence/image_adapters_20261018T103930Z_721a7d6b/summary.json`.
New helper: `signal_video/rtl/cip_image_threshold_fixed.v`; dispatcher, testbenches,
oracle, runner, generator/manifest, source list and ABI documentation updated.
Temporary binaries and generated model fixtures are automatically cleaned up.
No synthesis/resource/timing/board result is claimed; both adaptive branches
are instantiated where enabled and no device-fit inference is made.

## 2026-10-18 first legacy image ABI implementation

`signal_video/rtl/cip_image_threshold.v` now implements unsigned fixed-threshold
frame streaming (mode0); Otsu/adaptive modes remain explicitly unsupported in
this legacy ABI. Five DATA_W values (1/8/16/24/32) pass 1140 output checks and
139 completion responses, plus reset-recovery outputs. Simultaneous input/output,
CE/backpressure, latched configuration, invalid config and malformed input frame
markers are covered. The malformed frame is streamed with regenerated markers
and returns error2 at completion; the consumer must discard it. See
`signal_video/FUNCTIONAL_IMAGE_ABI.md`. The generator preserves this hand-written
adapter; remaining rejection templates now number41, alongside six functional
DSP adapters and this fixed-mode image adapter. This does not complete all
threshold modes or the remaining image ABI work. Combined functional source
compilation passes. No synthesis/resource/timing/board claim.

Local evidence: `evidence/image_adapters_20261018T103420Z_82954c8d/summary.json`.

## 2026-10-18 missing-DSP development addition

Adaptive mean/Gaussian pixel-stream frame frontend added, reusing two synchronous
line buffers and one statically selected threshold branch. W*H crops to
(W-2)*(H-2). Two modes x four widths pass112 commands/1064 pixels, including
24 invalid dimensions and16 marker-error frames; config/tag/CE/stalls/reset
recovery checked. No synthesis/timing/resource/board result is claimed.

Gaussian-weighted local adaptive threshold added, fixed separable3x3 [1,2,1]
weights with exact rational comparison. Expanded shared mean/Gaussian tests
pass 3400 external windows per mode (6800 combined), at 1/8/12/16-bit widths;
signed offset/invert/markers/CE/backpressure/config capture/reset covered.
No synthesis/timing/board result is claimed; see `image/filters/ADAPTIVE_THRESHOLD.md`.

Otsu histogram-to-threshold solver added: exact rational criterion with shared
serial wide multiplier and synchronous histogram RAM. Thirty-two histograms at
COUNT_W1/8/16/24 match independent Fraction class-mean variance, with empty/tie/
extreme-count/CE/response-stall/load-and-compute-reset checks. This entry is a
histogram solver; the separate same-frame wrapper is described below. No synthesis
or board result is claimed.
See `image/histogram/OTSU.md`.

The same-frame Otsu wrapper is now also implemented: capture, synchronous frame
RAM/histogram, exact solve and strict > binary replay. Five valid dimensions,
including 1x1 and default32x24, pass 80 completed commands/12264 pixels, including
10 malformed-marker frames and full recovery after reset. Separate insufficient
count capacity rejection passes. No synthesis/timing/resource/board claim.

Additional missing image function: `img_filter_adaptive_mean3x3` implements
signed-offset local adaptive binary threshold with exact rational window mean.
Four bit widths (1/8/12/16), 2600 numeric/configuration/marker/CE/backpressure/reset
checks pass. This is an external-window kernel, not full-frame/border generation;
no synthesis or board result is claimed. See `image/filters/ADAPTIVE_THRESHOLD.md`.

Six independent functional entries now exist under `dsp/rtl`: signed
coefficient-loadable FIR, coefficient-loadable IIR biquad, and parameterized
CIC decimator, rotation/vectoring CORDIC, rational polyphase FIR resampler,
and synchronous-memory block FFT/IFFT (2..256 points).
`cip_fir_stream`, `cip_iir_biquad_stream`, `cip_resampler_stream` have functional
command adapters. FIR: 69 modeled outputs plus reset recovery/11 responses;
IIR: 69 modeled outputs plus reset recovery/13 responses; resampler: four
configurations, 52 packets, 1292 outputs and 104 responses pass.
CIC command adapter: four parameter sets, 28 packets/442 outputs/40 responses
pass, with explicit output shift/saturation and partial checkpoint semantics.
CORDIC command adapter: 14 packets/126 vectors/756 full-precision serialized
words and 32 responses pass; all six word positions cover CE/backpressure
stalls. Odd-word packet abort and partial-pair/compute reset are covered.
FFT command adapter: all eight lengths, 80 normal packets/20400 output words/
344 responses pass. All six legacy DSP names now have functional adapters;
the 42 legacy image templates still reject commands and are not algorithm
validation evidence. Explicit `cip_dsp_*` entries remain directly available.
The package runner supports `--groups dsp`. FIR has 200 directed numeric checks;
IIR has 1200 independent integer-model output checks; four CIC configurations
have 3291 output checks across 14000 stimulus cycles. CE, output backpressure,
packet termination and reset are covered within the documented test scope.
CORDIC has 1154 bit-exact output comparisons and independent floating-point
accuracy checks, including full quadrants and coordinate/angle extremes.
Resampler has 1950 output comparisons across seven UP/DOWN/TAPS sets against
explicit zero insertion/full convolution/decimation; packet tails are covered.
FFT/IFFT tests cover all eight supported lengths: 112 valid frames/7140 bins,
46 malformed-frame responses and 510 additional reset-recovery bins. Fixed-point
outputs match integer references; independent direct DFT checks pass. Evidence:
`evidence/dsp_functional_20261018T094205Z_6785d246/summary.json`.
No synthesis or board acceptance is claimed for these new entries. Legacy
All six signal_video DSP wrappers are integrated at code/simulation level;
the explicit entries and adapters have documented interfaces.
See `dsp/README.md` for formats, latency and restrictions.

User scope: implement common IP and image functions in parallel; defer the old
300+ core inventory and crypto development. Changes stay inside this package.
No original board top, UART digest, crypto memory or baseline artifact was changed.

| Area | Result and functional scope |
|---|---|
| Image ISP and pipelines | RAW8/10/12 four-phase Bayer frontend, hardware gray-world AWB feedback, CCM, Gamma, contrast/brightness, RGB/YCbCr. Frame commit and complete dependencies are wired. |
| Filters and edges | Actual bilateral/guided/NLM/temporal processing, synchronous histories, complete Canny hysteresis, asymmetric-SE two-pass opening/closing; existing window kernels retained. |
| Image geometry | Internal-frame resize/rotation/mirror/affine/perspective, area-resampling downscale/SSAA resolve, integer bilinear enlargement. |
| Histogram and dehaze | Full-frame HE/CLAHE with strict clip redistribution/tile interpolation; same-frame DCP dehaze with automatic airlight and optional true guided refinement. |
| Multiple frames | Actual storage, OSD, frame difference, EWMA initialization/writeback, fusion, bounded SAD registration and translated canvas blending. |
| Memory | Actual stream-to-memory, memory-to-stream and decoded descriptor chain copies, partial final beats, errors and drain-on-abort. |
| Bus | AXI-Lite one-initiator address routing; actual bounded FIXED/INCR AXI4/native bridge and synchronous RAM compatibility endpoint. |
| Peripherals | Actual UART8N1, four-mode SPI, I2C, single/quad SDR QSPI, SD-v2 SPI initialization and CRC-checked 512B reads/writes. |
| Cross-group integration | New CE/native adapter and byte-address synchronous RAM; actual 11-byte DMA round-trip including physical response while CE=0. |

Recommended image entrypoints and all per-function restrictions:
[image/README.md](image/README.md). Other exact interface contracts are in each
group README/manifest. Compatibility names ending in `_stub` or `_placeholder`
in memory, bus and geometry now wrap functional implementations; the old
rejection testbenches and evidence remain available as historical records.

## Commands and actual results

Executed from the repository root, with the bundled OSS tool environment:

```powershell
. .\scripts\env.ps1
iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f
python cores/system/common_scaffold/run_tests.py --jobs 3
```

- Source package: 115 RTL files compile together, PASS. This count includes
  support and compatibility modules; it is not a count of 115 new algorithms.
- Individual top-level Icarus compile: 115/115 PASS, with 115 logs and a
  summary at
  [summary.json](board/tang25k/build/each_module_compile_20261015/each_module_compile/summary.json).
- Image: 82 source files/module names/manifest entries; paths, unique names
  and dependencies audit PASS; all six bounded reference groups PASS.
- Stream/bus, memory, peripherals and CDC groups: PASS.
- Stream/FIFO integration: 257 ordered words, CE/backpressure/reset/sidebands PASS.
- DMA/CE/memory integration: 11 bytes, byte strobes/tail/tag/length and retained
  response while CE paused PASS.
- Legacy signal_video templates: rejection-interface check PASS only. Their
  result is explicitly separate from algorithm functionality.

Final combined evidence:
[summary.json](evidence/all_20261015T125248Z_95f280bd/summary.json), with source
hashes and individual group logs. Image evidence:
[summary.json](image/build_groups_20261015_205251_832900/summary.json).

## Tang Primer 25K board smoke (2026-10-15)

The isolated `common_uart` harness was synthesized, placed/routed and packed
for GW5A-25, then loaded into FPGA SRAM over JTAG. Its UART loopback emitted
`CIP25K` followed by `PASS common_uart`; the raw 115200-baud capture and build
report are in
[board/tang25k/build/board_smoke_20261015.md](board/tang25k/build/board_smoke_20261015.md). This only
validates the UART smoke harness on the board, not the remaining IP modules.
The SRAM image is volatile; SPI flash was not written.

The scripts now provide one repeatable group entrypoint. These were small
development checks, not a per-core release acceptance campaign. Existing logs,
including failed runs, were preserved.

## Focused BRAM follow-up (2026-10-15)

After the initial GW5A sweep, the seven `MEMORY_LIBMAP` failures were corrected
without changing the old sweep artifacts. The image group and combined RTL
source compilation were rerun after these changes:

```powershell
python cores/system/common_scaffold/run_tests.py --groups image --jobs 2
. .\scripts\env.ps1
iverilog -g2012 -tnull -f cores/system/common_scaffold/rtl_functional_sources.f
```

Both passed. The focused image evidence is
[summary.json](evidence/all_20261015T144737Z_bcc09e4a/summary.json). The seven
affected tops now pass their directed Gowin RAM-mapping stage. Full synthesis
results differ by module and are recorded with preserved scripts and logs in
[focused_ram_fixes](evidence/gw5a_synthesis_20261015/focused_ram_fixes/README.md):
the two histogram modules completed full synthesis; dehaze mapping passed but
Yosys exited during SCC with a Windows stack overflow; filter, NLM, and opening/
closing mapping passed, while the filter frame engine's full synthesis was
stopped during a long ABC9 stage. No full resource result is claimed for the
last two cases.

## Remaining boundaries

The UART board smoke resource result must not be generalized to the package.
A separate GW5A per-top synthesis sweep across the 115 source tops completed:
97 PASS, 11 FAIL and 7 TIMEOUT. The seven original memory-mapping failures now
pass focused RAM-mapping checks. Four other tops exited abnormally in Yosys;
seven hit the 900-second cap. The
original 97/11/7 counts remain the historical full-sweep result; the focused
follow-up above did not rerun the full sweep. The summary and non-PASS logs
are preserved in
[evidence/gw5a_synthesis_20261015](evidence/gw5a_synthesis_20261015/README.md).
This is not a whole-system placement/routing or timing-closure result.
Whole image suites are not integrated into the 20K board top and have no
15K-LUT/4-DSP claim. Default frame capacities are
bounded and several algorithms use serial multi-pass processing/direct division.

Image enlargement provides interpolation and area resampling; there is no
trained super-resolution model. Automatic stitching implements bounded integer
translation; arbitrary homography comes from the caller. External frame/guide
identity, calibration and target memory bandwidth remain system responsibilities.
SD supports version-2 cards; QSPI is SDR; AXI4 burst formats and I2C multi-master
capabilities are limited as specified in the group documentation.

The old unified `signal_video/` DSP/image ABI templates remain explicit error
endpoints. Use the implemented `image/` entrypoints for image processing. Generic
template rejection tests do not complete the separate DSP-template algorithms.

## Image filter Tang Primer 25K consistency target (2026-10-16)

An isolated board top now exercises `img_filter_frame_engine` on a fixed 4x4
grayscale opening, checks each output pixel and frame marker, and reports
`FILTER PASS D=378E8AAB` over UART. Icarus simulation passed with that digest.
The isolated GW5A-25 build completed synthesis, place-and-route, and packing:
12,528 LUT4, 613 DFF, 2 BSRAM, 0 MULT12; routed clock results are 100.61 and
106.13 MHz. The bitstream SHA-256 is
`2e41a8ed86dc347fcee916720a32ca9dc73979875f1ca7d117313660d93642f8`.

Tang Primer 25K JTAG SRAM programming and UART readback now **PASS** for this
fixed 4x4 grayscale opening self-test. The board identified as GW5A-25
(`IDCODE 0x1281b`); `COM44` at 115200 8N1 returned `FILTER PASS D=378E8AAB`,
and the programmed image SHA-256 matched the build artifact. The raw record is
[board_uart_20261016_014945.txt](board/tang25k/build/image_filter_selftest_25k/board_uart_20261016_014945.txt).
The image was loaded into volatile SRAM; SPI flash was not written. This proves
only the tested filter configuration, not board-level operation of the other
image modules. See [the Tang 25K board README](board/tang25k/README.md) and the
simulation/build evidence under `board/tang25k/build/image_filter_selftest_25k/`.

## Geometry inverse-map Tang Primer 25K consistency target (2026-10-16)

The fixed 4x4 perspective-coordinate self-test passed Icarus simulation and
GW5A-25 synthesis, place-and-route, and packing (651 LUT4, 395 DFF, 302 ALU,
0 BSRAM, 0 DSP; post-route Fmax 207.04 MHz). The first generated `.fs` used
Gowin's `-c` compression option and was rejected by `openFPGALoader` before
device programming. The board build script now emits an uncompressed SRAM/JTAG
image. Its SHA-256 is
`dd347b8689a231b2a016b0202445c4e06e3d73ed7f3d00fc53cb00c47dedd313`; JTAG
programming exited 0 and COM44 returned repeated `GEOMAP PASS` lines. The raw
record is
[board_uart_uncompressed_20261016_020513.txt](image/geometry/board_selftest/build_gw5a25_20261016_015749_41868/board_uart_uncompressed_20261016_020513.txt).
This board result covers `img_geo_inverse_map` with the one specified 4x4
perspective map. SPI flash was not written; it does not establish board-level
validation of the other geometry algorithms.

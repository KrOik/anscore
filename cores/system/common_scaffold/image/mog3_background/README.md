# Three-Gaussian grayscale background segmentation

`mog3_background_frame.sv` maintains three persistent Gaussian components per pixel and emits foreground segmentation plus a dominant-background estimate. This is a complete fixed-point MOG3 variant with matching, weight learning, mean/variance updates, normalization, score sorting, and cumulative background selection. It is different from the existing single EWMA/median models. It is not OpenCV MOG2: it has exactly three components, no shadow detection, no adaptive component count, and uses the explicitly specified update rules below.

## API and geometry

Parameters WIDTH/HEIGHT are positive with WIDTH*HEIGHT<=1024; each axis<=1024. The 1024-pixel bound is deliberate. The core is intended for bounded tiles/small grayscale frames, not an unsupported full-HD claim. Pixel depth is 8 bits. Each pixel stores 3*(9+16+16)=123 bits in a synchronous-read/write model RAM. At 32x32 the actual Gowin synthesis maps this memory to7 SPX9 block RAMs.

Every start_valid/start_ready transfer atomically latches cfg_learning_shift[3:0], cfg_match_sigma2[4:0], cfg_background_threshold[8:0], cfg_initial_variance/cfg_min_variance[15:0], and cfg_reset_models. There is no separate configuration commit. Valid ranges are learning_shift1..8 (alpha=2^-shift), squared matching threshold1..25, cumulative weight threshold1..256, variance floor1..65025, and initial variance between floor and65025. An invalid start produces held done_valid/done_error with error_code1, consumes no pixels and preserves the previous model state, including when cfg_reset_models was requested.

An accepted valid start captures exactly N raster pixels on s_gray/s_valid/s_ready, with s_sof only on pixel0 and s_eol on each row's final pixel. The core serializes each input pixel with its output. m_foreground, m_background[7:0], m_match[1:0] and m_sof/eol/last transfer on m_valid/m_ready. m_match is the selected prior sorted component0..2, or3 for no match. It is not an index in the newly sorted updated model. m_background is the prior highest-score component's mean, rounded to an integer; it is not a weighted average over the prefix.

All handshakes and internal state progression require CE=1. Ready is gated by reset and CE. Output data/metadata and model state hold under output backpressure and disabled CE. done_valid, done_error and error_code remain stable until done_ready with CE enabled. A new start is possible only after acknowledging DONE. There is no timeout for missing input or output acceptance.

Reset is synchronous active-low, overrides CE, clears control/model initialization and invalidates output/done. Model RAM is intentionally not cleared: the next complete frame initializes every location before it can be reused. cfg_reset_models likewise cold-starts the next accepted valid frame without clearing RAM in a separate host operation. The first observation at every cold pixel initializes component0 to weight256/mean=pixel and variance=initial; other components have zero weight. That observation is classified as background with m_background=pixel and m_match=0.

## Exact arithmetic and algorithm

Means use unsigned Q8.8 in0..65280, variances use integer pixel-squared units in1..65025, and weights are integer Q0.8 units in0..256 with exact sum256. Signed EMA increments round nearest, ties away from zero. Matching compares the full Q8.8 residual square to sigma2*variance*65536, including equality. No floating arithmetic or host-precomputed model maps exist in the RTL.

For each initialized pixel:

1. Load all three components synchronously. Clamp each variance upward to the current configured floor, then stable-sort descending by weight/sqrt(variance), comparing exact weightA²*varianceB against weightB²*varianceA without square roots or division.
2. Find the first positive-weight component satisfying the squared-distance test. All three distances are calculated. Select the smallest prefix whose cumulative prior weight reaches the configured threshold. The sample is background iff it matched inside that prefix; otherwise it is foreground. Output the prior first component's rounded mean as the background estimate.
3. For every weight, apply w += round((256*hit-w)/2^shift). A match updates its Q8.8 mean with the same alpha and updates variance toward the old-mean squared residual rounded to integer units. Clamp mean to0..65280 and variance to[floor,65025]. Unmatched components retain their means and variances.
4. If no component matched, replace the prior weakest-score component2 with the current mean, configured initial variance and weight round(256/2^shift), after decaying the other weights. A replacement is not retroactively classified as background.
5. Normalize all three raw weights: floor(256*w/sum), then assign the remaining0..2 units to the largest raw-weight component, lower prior index winning ties. This preserves exact sum256 and does not activate an unused zero-weight component merely to absorb normalization remainder.
6. Stable-sort the updated components by the same score and synchronously write the complete123-bit model word. Publish the pixel result and hold until consumed.

A single serial unsigned shift/add multiplier and a serial restoring divider are shared across distance, score and normalization calculations. This prioritizes area rather than pixel-per-clock throughput. Initialized pixels require roughly1100 enabled clocks, plus stream stalls; the first cold frame is faster. No DSP is required in the measured isolated synthesis.

## Framing errors and recovery

Malformed SOF/EOL sets done_error/error_code2 and the frame still consumes N inputs and emits N deterministic outputs. Writes within that failed frame are not rolled back. At its final output acceptance, the entire model is marked uninitialized, so the next valid frame automatically rebuilds all N models even if cfg_reset_models=0. This prevents continuing from a partially updated erroneous frame. Tests verify this automatic cold recovery with exact model words. An external reset during capture/arithmetic/held output also invalidates the model; a following full frame rebuilds it. Error code3 is reserved for an invalid internal control state and also invalidates initialization.

## Evidence and limits

Run from repository root:

```
python -B cores/system/common_scaffold/image/mog3_background/run_tests.py
python -B cores/system/common_scaffold/image/mog3_background/run_synthesis.py
```

Independent integer oracle checks every emitted foreground/background/match/marker result and every complete123-bit RAM model word. Profiles1x1,1x7,7x5 run64 temporal frames each; maximum-capacity32x32 runs3 frames. Including one complete post-reset recovery frame per profile and11 targeted boundary frames,210 complete frames /6902 pixels pass. These sequences include stationary noise, two alternating background intensities, moving foreground, brightness changes, model reset, learning shifts1..8, all three active components, incorrect markers with automatic cold rebuilding, output/CE stalls, held DONE, and disabled-CE resets during capture/arithmetic/held output.Boundary frames additionally exercise variance65025/sigma25/background threshold256, exact squared-distance equality and the next integer input beyond it, and a secondary component entering/leaving the selected background prefix.53 invalid configurations are rejected, including invalid learning/matching/background thresholds and variance bounds; invalid reset requests preserve the old model.

An independently coded floating-point version of this exact variant processes the same5824 temporal pixel observations. It has zero foreground decision differences on these fixtures. The fixture comparison asserts foreground disagreement <=1%, background maximum error <=4 grayscale units and mean error <=1 unit; these guard against gross divergence while allowing fixed-point quantization and component decisions. They are fixture tolerances rather than scene-independent guarantees. Maximum observed dominant-background difference is0.501026 grayscale units; per-profile mean errors and all counts are in test_evidence.json. This finite fixture agreement is not a general accuracy bound or evidence of MOG2 equivalence. There is no real-scene quality dataset or board signoff yet.

Isolated Gowin synth -noalu -nodsp / check passes with zero problems. Full1024-pixel32x32 core:2462 LUT1..4 +360 MUX2_LUT5 +3 MUX2_LUT6,634 FF,7 SPX9 +4 RAM16SDP4,0 DSP. Small7x5 core:2741 LUT1..4 +501 MUX2_LUT5 +2 MUX2_LUT6,753 FF,97 RAM16SDP4,0 DSP. Both are below15K LUT /4 DSP, but these are synthesis counts only: no placement, frequency, hold or board qualification is claimed. All temporary simulation binaries and synthesis netlists are automatically deleted; only compact evidence is retained.

reference.json records successfully retrieved OpenCV classic-mixture and MOG2 implementation sources reviewed for background mixture context. Their exact policies differ from this explicitly specified fixed-point variant. No implementation source was copied.

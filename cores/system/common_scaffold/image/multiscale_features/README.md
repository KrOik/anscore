# Automatic multiscale feature descriptors

`multiscale_features_frame.sv` is a real synthesizable image-frame-to-feature front end. Host software supplies only pixels and a FAST contrast threshold; no keypoint coordinates or host-side stage scheduling are supplied. One shared RTL datapath constructs Gaussian pyramid levels, calculates FAST9 scores, applies deterministic3x3 NMS, calculates intensity-centroid orientation and samples rotated256-bit BRIEF pairs. A single input frame produces descriptors at every requested scale. This is not a complete OpenCV ORB implementation: it omits scale-distribution quotas, Harris ranking, learned ORB pattern, descriptor preblur and OpenCV angle arithmetic.

## Geometry and numerical definition

WIDTH/HEIGHT are static1..256, total source pixels<=65536; BITS is8/10/12, LEVELS1..3, RADIUS1..15. The original image is level0. Additional levels repeatedly apply exact25-tap outer product [1,4,6,4,1], REFLECT_101 border, `(sum+128)>>8`, sampling source(2x,2y). Sizes round upward on halving. Dimension1 repeats its sole coordinate. There is no intermediate horizontal rounding. The independent oracle agrees exactly with actual OpenCV pyrDown over18 generated reductions (27 total levels including9 original images), including thin/odd dimensions and uint8/uint16 data.

For each interior FAST radius3 circle, strength is the maximum over16 cyclic starts of the minimum same-sign contrast over9 contiguous pixels. If strength>frame_threshold store score=strength-1, otherwise0; border scores0. NMS requires positive score and suppresses if an in-frame3x3 neighbor has greater score or equal score and earlier raster position. The positive-score rule also suppresses the strength1/threshold0 case. This matches the existing FAST→NMS integration contract. Actual OpenCV FAST9 nonmaxSuppression=False coordinate sets are independently cross-checked; the deterministic tie rule is explicitly this core's rule.

Only NMS survivors with the complete radius(R+1) square fitting the level receive descriptors. A too-small level legitimately produces no features. Orientation is the circular radiusR intensity centroid. Sixteen Q7 direction vectors maximize the moment dot product, equal maxima selecting the smallest index; angle k represents k*22.5 degrees in image coordinates(+x right,+y down). Zero moments select angle0/orientation_valid0. This quantizer's maximum geometric error is11.633634degrees, conservatively<12degrees. The inherited radius-specific BRIEF patterns are actually rotated and integer-rounded half-away-from-zero; descriptor bit i is intensity(sampleA)<intensity(sampleB), equality0. No grayscale clipping, implicit smoothing or contrast normalization occurs.

Output fields: `m_descriptor[255:0]`, `m_angle[3:0]`, `m_orientation_valid`, `m_score[BITS-1:0]`, `m_x/m_y` (coordinates within the level), `m_original_x/m_original_y` (coordinates multiplied by2^level), and `m_level[1:0]`. Results are ordered by increasing level, then raster position. Output descriptors represent automatic detections; there is no host keypoint input. Mapping to original pixels uses the actual pyrDown sampling origin, without an invented half-pixel offset.

## Lifecycle and errors

After reset, threshold defaults20. cfg_valid/cfg_ready updates it only before the first pixel of a frame. Configuration takes priority over a simultaneous first input beat. The threshold is snapshotted at the first accepted pixel and shared by all levels. All handshakes require rst_n && ce && valid && ready. Ready outputs include CE; registered output valid/data remain stable during backpressure or CE pause. Input pixels are row-major with SOF only at the first pixel and EOL at each real row end. Capture completes before any processing/output, so a marker error terminates with no descriptors for that malformed frame.

`done_valid` holds after all feature outputs have been consumed, including frames with zero features; done_ready releases the next capture. Bad marker sets frame_error/error_code1; illegal state2; custom pattern offset outside[-R-1,R+1] sets3 and terminates rather than reading an invalid sample. A pattern error discovered after earlier descriptors can leave a partial result set; clients must reject the frame on frame_error. No valid descriptor is fabricated. After error completion acknowledgment, restart a whole frame with fresh SOF. There is no timeout or autonomous SOF search.

Synchronous active-low reset overrides CE and aborts capture, processing or output. RAMs are not cleared: a whole new capture and fully generated levels/scores precede reuse. Prior stale pixels cannot become descriptors. Threshold resets to20, so reconfigure it when needed. Invalid parameters fail elaboration/simulation. PATTERN_FILE defaults to the matching existing oriented_brief radius ROM; paths resolve relative to repository root, or override with an absolute path. This core does not modify those frozen ROMs or any existing source.

## Architecture, resource scope and evidence

The hardware time-shares a single score engine, orientation unit and descriptor sampler across levels. One synchronous pixel RAM stores source plus the generated levels (N+ceil(W/2)*ceil(H/2)+ceil(W/4)*ceil(H/4) pixels for3 levels). One synchronous reusable score RAM reserves N entries. One synchronous4096x24 rotated-pattern ROM is used. Pixel and score reads are explicitly registered. Level-dependent strides are selected from elaboration constants, avoiding a general runtime image-stride multiplier. Serial shift/add implements orientation dot products; synthesis disables DSP inference.

Default65x65/BITS8/LEVELS3/R3 has layer sizes65/33/17 and all layers yield actual descriptors in the regression. R15 is supported and tested with71x69/BITS10/LEVELS2 (layers71x69 and36x35, both containing valid detections). Larger R15 three-level configurations are functional configurations, not a claim they fit a particular board. A resource profile is accepted only after its own complete-chain synthesis; logical RAM bits alone do not prove physical fit. No claim is made for full-resolution/live-video throughput, timing closure or board acceptance.

Commands from repository root:

```
python -B cores/system/common_scaffold/image/multiscale_features/run_tests.py
python -B cores/system/common_scaffold/image/multiscale_features/test_external.py
python -B cores/system/common_scaffold/image/multiscale_features/run_synthesis.py
python -B cores/system/common_scaffold/image/multiscale_features/run_synthesis.py --radius15
python -B cores/system/common_scaffold/image/multiscale_features/test_rom_binding.py
```

The end-to-end independent integer/Python oracle checks every generated pyramid pixel and every output field of1606 automatic descriptors across20 normal frames:3x1/L3/R1,19x17/L1/R3,65x65/L3/R3,71x69/B10/L2/R15. Inputs include independent random textures, coarsely scaled textures, a real quarter-turn rotated square texture, translated textures, constant no-corner frames and repeated frames. All levels in the main multiscale profiles produce detections, including the second radius15 layer. It additionally checks four complete constant-frame recoveries after CE-disabled resets, malformed-marker completion and recovery, continuous frames, metadata/order, output backpressure stability and done holding. This evidence is bounded functional validation, not feature-matching accuracy, scale/rotation invariance quality evaluation or a board certificate.

Final whole-chain Gowin synthesis (`-noalu -nodsp`, `check -assert`) results:

| Profile | LUT-class incl. LUTRAM | FF | Block primitives | Conservative9Kb units | DSP |
| --- | ---: | ---: | --- | ---: | ---: |
| 65x65 B8 L3 R3 | 9938 | 1167 | 6 DPX9B +6 SP | 24/46 | 0 |
| 71x69 B10 L2 R15 | 10472 | 1196 | 10 DPB +3 SP | 26/46 | 0 |

LUT-class counts include all LUT1..4, ALU/MUX and4 LUTs per RAM16SDP4 (3 such cells in each profile). Every block primitive is conservatively charged as two9Kb units; raw primitives are retained for independent checking. Both tested full-chain profiles fit the declared15K LUT/4DSP/46x9Kb bounds. Logical pixel+score+pattern storage is176928bits for the default and208884bits for the radius15 profile, before memory fragmentation. This is a synthesis fit result, not place-and-route or timing acceptance. The additional ROM-binding audit independently compares all4096 entries from Yosys's derived default and radius15 memory initialization against the intended frozen assets, preventing a parameter-dependent-ROM substitution from silently passing resource reporting.

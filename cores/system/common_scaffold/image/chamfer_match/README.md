# Directed squared-distance Chamfer edge-template matching

This core implements a complete **same-source-frame** edge-template match: capture the binary template mask, capture a binary image through the real frozen Euclidean distance transform, store the complete squared-distance field in synchronous RAM, then evaluate every valid translated template window. It outputs the full score map and best window origin. There was no Chamfer implementation in the searched project/host/script RTL and Python source; ZNCC and standalone distance transform are separate capabilities.

## Exact score and limits

For binary image edges E and binary template edge offsets T, at valid window origin `(x,y)`:

```
D2(u,v) = min over (ex,ey) in E of ((u-ex)^2 + (v-ey)^2)
sum_squared(x,y) = sum over (tx,ty) in T of D2(x+tx,y+ty)
score_Q8(x,y) = floor((256*sum_squared + floor(|T|/2)) / |T|)
```

This is directed **mean squared Euclidean distance** Chamfer matching. It is not mean unsquared distance, symmetric Chamfer, an approximate 3/4 chamfer distance transform, SAD, ZNCC, or an orientation-aware distance. The denominator counts actual template edges, not the template rectangle area. Lower scores are better; exact zero means every template edge coincides with an image edge. Extra image edges are not penalized. The best tie selects the earliest row-major window; for a fixed template, Q8 resolution is sufficient to preserve strict ordering of distinct integer sums because |T|<=64.

WIDTH/HEIGHT are each 1..32. Runtime template width/height are each 1..8 and no larger than the image. A maximum 32x32 squared distance is 31²+31²=1922. With at most 64 template edges, a conservative sum bound is 123008, held in 18 bits. This algebraic sum upper bound is not claimed geometrically attainable simultaneously at every point of an 8x8 window. Normalization dividend including rounding is under 2^25. Finite Q8 score is at most 492032. Both public score and raw sum are unsigned32.

No image edges or an empty template are explicit data-invalid cases: every map output has `m_invalid=1` and `m_score=m_sum_squared=FFFFFFFF`, `best_valid=0` and all best metadata zero. They complete successfully with no protocol error. Invalid scores never participate in best selection.

The reused euclidean_distance core defines **zero input as feature**; this wrapper feeds `!s_edge` so an edge bit 1 is the matching feature. It computes the complete field from the same captured image and is reset outside its active frame/transform phases. No distance map or golden result is supplied by the host. Its RTL is read-only and unmodified.

## Transactions

START is start_valid/start_ready; it snapshots template dimensions and clears every output/best/error field and template edge count, including a rejected START. Supply exactly template_width*template_height binary template tokens through t_valid/t_ready with SOF/EOL/LAST, then exactly WIDTH*HEIGHT binary image tokens through s_valid/s_ready and the analogous markers. Both are raster streams. A template-marker error consumes the entire template then returns error without accepting an image. An image-marker error consumes the complete image and returns error without any score prefix.

External image markers are validated by the wrapper, while valid markers are regenerated for the distance-transform child. This deliberately prevents the child's immediate marker-error stop from deadlocking an external stream that the wrapper has promised to consume completely. The external image edge acceptance and child input acceptance still use the exact same valid/ready handshake.

All transfers require CE high on the rising edge; ready outputs include CE. Active-low synchronous reset overrides CE. RAMs are not reset; template capture and the complete fresh distance transform overwrite all subsequently read cells. START accepts no overlapping frame. Source/template ready are low throughout scoring and held completion. Missing inputs wait normally; there is no abort or timeout port.

Output map contains one token per legal origin in raster order, with m_x/m_y, m_score (Q8), m_sum_squared, m_invalid, SOF/EOL/LAST. EOL marks the final valid window of a row, not image width-1. Tokens remain stable through CE pauses and backpressure. `template_edges` is the accepted template edge count. Best metadata updates as map tokens are generated and is definitive at successful DONE. `done_valid` is held until CE and done_ready. `busy` includes held completion.

Error codes are enumerations: 1 invalid static/runtime configuration; 2 template marker error; 3 image marker error; 4 child/transform completion error; 5 illegal wrapper state. Protocol/configuration errors produce no map prefix. Artificial internal failures after scoring starts are transaction failures and may follow a provisional prefix; consumers must commit only on successful DONE. FAILED resets the child, enabling subsequent normal START without an external reset after completion acknowledgment.

## Reproduce and evidence

```powershell
python -B cores/system/common_scaffold/image/chamfer_match/run_tests.py
python -B cores/system/common_scaffold/image/chamfer_match/test_protocol.py
python -B cores/system/common_scaffold/image/chamfer_match/test_invalid_parameters.py
python -B cores/system/common_scaffold/image/chamfer_match/test_numeric_limits.py
python -B cores/system/common_scaffold/image/chamfer_match/synth_check.py
```

The independent oracle brute-forces all actual 2-D edge coordinates for every image point, sums translated template edge samples and normalizes with Python integers. Actual SciPy distance_transform_edt(~image) squared/rounded must agree with the entire field for images with edges. No-edge images use the explicit invalid contract rather than SciPy's outside-image feature convention. RTL tests check every stored distance cell and every output score/sum/location/invalid flag/marker plus best metadata. Directed arithmetic tests separately cover all 64 denominator values and conservative bounds; these injected arithmetic-domain tests are not represented as real image frames.

Full isolated synthesis includes the actual frozen euclidean_distance RTL, all field/template/child memories and the wrapper. `synth_gowin -top chamfer_match -nodsp; check -assert; stat` maps the flattened hierarchy. Both ALU and MUX counts are retained in the area evidence. This is area evidence, not timing closure, P&R, board validation or a video-rate claim.

Network reference URLs and actual retrieval status are recorded in references.json. GitHub requests timed out during this task; no successful download is fabricated. The actual installed SciPy source file is hashed and SciPy is executed in the numerical reference. The frozen distance core's own documentation and test contract are additional local references. No upstream source is copied into this RTL.

Only this new directory is edited. All large simulation/synthesis artifacts are generated in TemporaryDirectory and automatically removed. Compact source/docs and JSON evidence remain; original dependency artifacts/logs are preserved.

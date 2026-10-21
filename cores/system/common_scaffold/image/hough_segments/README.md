# Finite Hough support segments

`hough_segments.sv` extracts real finite edge-supported segments for **one supplied polar candidate per frame**. It does not discover theta/rho peaks itself, does not clip an infinite line to the image rectangle, and is not a drop-in implementation of OpenCV probabilistic Hough. An upstream polar Hough implementation or host can supply `cfg_theta` and `cfg_rho` using the convention of `hough_lines_full`. The only RTL dependency of this narrow core is its local trigonometric ROM; it does not instantiate the full polar accumulator.

The initial repository search of source in `projects`, `host` and `scripts` for `houghlinesp|hough.?segment|max.line.gap|min.line.length` found no existing finite-line segment implementation. Existing polar peak outputs alone do not supply segment endpoints. The new core fills that endpoint-extraction gap without changing frozen kernels.

## Exact algorithm

The complete binary edge frame is captured to synchronous-read RAM. For actual edge pixels only, shared serial shift/add multiplication evaluates `dot=x*cosQ14(theta)+y*sinQ14(theta)`. The signed rho bin is nearest integer with half ties away from zero. A support pixel must satisfy `abs(pixel_rho-cfg_rho)<=cfg_rho_tolerance`; there are no synthesized support pixels.

For normal angle theta, the line is scanned in increasing x if `abs(sin)>=abs(cos)` and otherwise in increasing y. This is a dominant-axis raster order along the candidate line, not an arbitrary frame-raster order or a claim of exact sorting by continuous tangent projection. At each longitudinal coordinate, the core chooses one **real edge pixel** in the support band minimizing `abs(dot-rho*16384)`. Equal residuals choose the lower perpendicular coordinate. This documented representative rule keeps thick lines from multiplying support counts or generating fabricated endpoints.

Consecutive representatives belong to the same segment iff the number of missing dominant-axis positions between them is at most `cfg_max_gap`. A segment starts at its first actual representative and ends at its last actual representative; trailing gaps do not extend an endpoint. It is emitted only if its representative count is at least `cfg_min_support` and the squared Euclidean distance between endpoints is at least `cfg_min_length^2`. Both comparisons are inclusive. Segments are output in increasing dominant-axis order, limited by `cfg_max_segments`; they are not ranked by score or globally deduplicated across supplied candidates. The core consumes one complete frame for each candidate; an upstream system must replay the frame when requesting additional candidates.

## Parameters and stream contract

WIDTH and HEIGHT are each 1..32. START snapshots theta 0..179 degrees, signed rho -45..45, rho tolerance 0..3 bins, max_gap 0..31 positions, min_length 1..44 pixels, min_support 2..32 representatives, and max_segments 1..32. Invalid configurations return held error 1 without accepting image data. Accepted START clears output metadata even when the configuration is invalid. `TRIG_FILE` defaults to `trig.mem` in the working directory and may be overridden with an absolute path. `generate_tables.py` reproduces the signed Q14 sine/cosine ROM.

All accepted START, input, output and completion transfers require CE high on the clock edge. Ready outputs include CE. Synchronous active-low reset overrides CE and resets control/output validity, without resetting RAM. START readiness resumes only after held completion is acknowledged. A short serial calculation of min_length squared occurs after START and before input readiness.

Input valid/ready carries one binary edge and SOF/EOL/LAST markers for exactly WIDTH*HEIGHT accepted samples. SOF is required exclusively on the first sample, EOL exclusively at each row end, LAST exclusively on the final sample. Any marker error consumes the remaining frame and returns error 2 with no output prefix. Error 4 denotes an illegal internal controller state; codes are enumerations. There is no abort input.

Output valid/ready carries unsigned endpoint coordinates `m_x1,m_y1,m_x2,m_y2`, `m_support` (selected representative count), `m_length_squared` (exact integer squared Euclidean endpoint distance), and zero-based `m_index`. Endpoints always refer to accepted edge pixels. Tokens remain stable during backpressure and CE pauses. There is no LAST bit; held `done_valid` follows all accepted output segments, including zero-segment frames. Completion acknowledgment requires CE and done_ready. `busy` includes held completion. Metadata after valid deassertion is not an output token; a later rejected START clears it completely.

## Reproduce and limitations

```powershell
python -B cores/system/common_scaffold/image/hough_segments/run_tests.py
python -B cores/system/common_scaffold/image/hough_segments/test_protocol.py
python -B cores/system/common_scaffold/image/hough_segments/test_invalid_parameters.py
python -B cores/system/common_scaffold/image/hough_segments/synth_check.py
```

The independent integer oracle collects all real support coordinates, globally sorts records by dominant coordinate/residual/perpendicular coordinate, and groups gaps. It does not copy the RTL nested RAM scan or controller. Every emitted endpoint, count and squared length is compared exactly, and both endpoints are additionally checked against the original edge image. Tests include separated/joined segments, the exact max_gap boundary, non-four-direction lines, negative rho, one-pixel dimensions, ties, random angle/noise combinations, support/length thresholds, limit truncation and many distinct short segments.

Actual OpenCV `HoughLinesP` runs on every fixture with fixed RNG seed. Known horizontal/vertical/full-width fixtures verify real returned supporting subsegments; merged horizontal, vertical and full-width cases also achieve exact endpoint agreement. PPHT may stop at interior pixels and chooses candidates probabilistically, so all endpoint differences and exact-match flags are retained explicitly. Its full output list is not claimed identical to this deterministic per-candidate scan. The OpenCV source and scikit-image reference URLs/hashes are in `references.json`; no upstream source is copied into the RTL.

The full synthesis dependency set is this core plus trig.mem. Complete isolated mapping passes with no DSPs and `check -assert`; see synthesis_result.json. Optional combination with the separate full polar Hough core would require a frame-replay/controller wrapper, which is not provided or claimed verified here. This is area-oriented serialized processing, not a pixel-per-clock or overlapping-frame core. No board testing, placement/routing or timing closure is claimed. Temporary simulations and synthesis logs are automatically removed with TemporaryDirectory; only small delivery assets/evidence remain.

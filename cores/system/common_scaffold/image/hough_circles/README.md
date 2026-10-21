# Binary-edge circular Hough detector

`hough_circles_frame.v` performs a genuine three-parameter circle Hough
transform. For every input edge pixel and every configured integer radius,
unique integer midpoint-circle offsets vote for possible center coordinates.
The complete center/radius accumulator is retained. A global maximum is emitted,
nearby center/radius bins are suppressed, and maximum selection repeats.
This is not a local shape check, FAST corner detector, or gradient heuristic.

Input is an already computed binary edge map (`s_edge`), not grayscale data.
Sobel/Canny thresholding must be supplied upstream. Circle parameters are
integer center coordinates and radius; no subpixel fit is implied.

## Limits and selection semantics

WIDTH and HEIGHT are positive static parameters, each at most 32 (1024 pixels
maximum). `MAX_RADIUS` is 1..31 and `MAX_CIRCLES` is 1..32. A START snapshots
inclusive runtime minimum/maximum radius, a positive 8-bit vote threshold,
maximum result count, center NMS radius and radius-bin NMS distance. Runtime
radii must lie in 1..MAX_RADIUS, result count in 1..MAX_CIRCLES and NMS distances
in 0..31. Illegal runtime configurations produce held errored completion
without accepting pixels. Illegal static parameters terminate simulation.

Center candidates are restricted to the image rectangle. Circle circumference
points outside the image do not vote; partially visible circles and radii
larger than either image dimension are therefore legal. The radius31 boundary
fixture explicitly covers this behavior. Centers outside the image are not
searched, unlike an expanded/full-output Hough transform.

Scores count **unique circumference pixels**, not normalized circumference
fractions. All votes have unit weight. Larger or less-occluded circles can
therefore have higher raw scores; tune thresholds appropriately. Counts for
radii1..31 range from4 to176. The conservative bound8r≤248 ensures the 8-bit
accumulator cannot overflow for legal binary frames and unique offset tables.
Unexpected saturation is nevertheless reported as an error.

The highest remaining score at least the threshold is selected. Ties use
radius ascending, then y ascending, then x ascending. Following result
acceptance, a candidate is cleared if **both** its radius difference is at
most `cfg_radius_nms` and its squared Euclidean center distance is at most
`cfg_center_nms²`. These bounds are inclusive. Center-NMS0 / radius-NMS0 removes
only the identical bin. Radius-NMS0 preserves concentric circles with different
radii. Results are emitted in nonincreasing vote order. Reaching the configured
result limit returns the requested top K with normal completion; it does not
claim that no other circles remain. A below-threshold accumulator returns zero
circles with normal completion.

## Stream and error contracts

`rst` is active-high synchronous and overrides CE. START transfer is
`ce && start_valid && start_ready`; config changes or START while busy have no
effect. Each valid START clears the entire accumulator before `s_ready` becomes
available. Reset does not reset the RAM array; a new valid START always clears
all locations, ensuring recovery from interrupted voting or NMS.

Exactly WIDTH×HEIGHT edge pixels are accepted in raster order on
`ce && s_valid && s_ready`. Input backpressure can be lengthy while voting an
edge point over all radius offsets. SOF must mark only the first pixel and EOL
each final column. Output circles begin only after the whole frame is accepted.
Malformed markers consume the fixed-size frame and suppress **all** circle
outputs, returning an errored completion. The next START clears errors and RAM.

Circle transfer is `ce && m_valid && m_ready`. Payload x/y/radius/votes and
zero-based `m_index` remain stable under backpressure and CE=0. Ready signals
are low during CE=0; valid remains visible and must be qualified with CE by
consumers. `done_count` counts accepted output circles. `done_valid` remains
held until `ce && done_valid && done_ready`; busy includes pending output and
completion. Another START is available only after completion acknowledgement.
There is no per-circle LAST: completion provides the final count, including
the normal zero-result case.

Sticky `error_code` bits report:

- bit0 missing SOF; bit1 extra SOF; bit2 missing EOL; bit3 extra EOL;
- bit4 illegal runtime configuration;
- bit5 unexpected accumulator saturation;
- bit6 illegal internal state.

`done_error` accompanies errored completion. A consumer must discard the frame's
results if an internal error is reported after a prefix was emitted. Reset
provides explicit early cancellation at any stage.

## Memory and arithmetic

The accumulator has WIDTH×HEIGHT×MAX_RADIUS 8-bit entries, with one synchronous
read/write port and a serialized read/modify/write vote. It is addressed by
radius, y and x. Global-peak scans and suppression reuse that physical port.
All coefficient accesses are synchronous; no large asynchronous reg-array
accumulator is introduced. Constant stride address calculations and small NMS
squares use explicit shifts/adds, requiring no DSP.

`offsets.mem` is a 4096×12-bit synchronous ROM of signed six-bit x/y offsets.
`metadata.mem` supplies each radius's start/count. The ROM includes all31 legal
radii independent of MAX_RADIUS. `generate_tables.py` reproducibly generates
unique midpoint-circle samples. Pass both assets with the RTL, run from this
directory, or set `OFFSET_FILE` / `META_FILE` to absolute paths.

This implementation favors area and exact deterministic voting. Worst-case
latency grows with edge count times summed ring lengths, plus repeated complete
accumulator scans for NMS. It is not a continuous one-pixel-per-cycle detector.

## Verification

From the repository root:

```powershell
python -B cores/system/common_scaffold/image/hough_circles/run_tests.py
python -B cores/system/common_scaffold/image/hough_circles/synth_hough_circles.py
```

The oracle independently enumerates every candidate center and directly sums
its circumference edge samples; it does not emulate the RTL's edge-driven
voting controller. Geometry comes from actual scikit-image0.25.2
`circle_perimeter`, and all31 generated ROM rings are checked against its
unique coordinate sets. Another test compares all140 pre-NMS RTL accumulator
bins against the exhaustive model.

Actual `skimage.transform.hough_circle` calls compare full accumulator volumes
on14 fixtures (not only peak labels). That implementation votes repeated
symmetry points at axes/diagonals. The audit explicitly subtracts only that
known repeated-point multiplicity before checking equality with this core's
unique-pixel score. Raw skimage scores are recorded separately; raw bit-exact
equality is not claimed. Public skimage and OpenCV source URLs were actually
downloaded and hashed in `references.json`; OpenCV's gradient detector is a
different interface and is not claimed as an equivalent test oracle.

Main tests comprise25 frames, including known single/multiple/concentric circles,
radius31 boundary circles, full radius15 with84 votes, no-edge frames, dense
maps, deterministic random noise, degenerate1×1 geometry, and all four marker
errors followed by recovery. Ten CE=0 reset phases each recover with a healthy
frame. Additional tests cover9 invalid configs,8 invalid static cases, the
32-circle result/index/count boundary, held outputs and completion, ignored
busy config changes, CE pauses, and all140 accumulator bins. All output tuples,
scores, order, errors and terminal counts are checked exactly.

Full isolated synthesis and `check -assert` pass 7×5/MAX_RADIUS4,
16×16/MAX_RADIUS8 and32×32/MAX_RADIUS31/MAX_CIRCLES32. LUT1..4 totals are
592/478/504, ALU403/364/372, FF202/203/216, DSP0. RAM mapping is respectively
3SP+18RAM16SDP4, 3SP+1SPX9 and19SP, including both geometry ROMs. These are
isolated mappings, not routed timing, whole-system fit, or board validation.

All generated simulator/build artifacts use TemporaryDirectory and are removed.
Only small RTL/ROM/reference/evidence files remain for delivery.

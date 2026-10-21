# Joint spatial-color mean-shift filtering

`mean_shift_frame.sv` is an actual iterative RGB mean-shift filtering and
segmentation frontend. The full-project RTL/manifest search found no existing
mean-shift kernel. It does not substitute a box filter or K-means palette.
Each output starts from its original five-dimensional center `(x,y,R,G,B)`.
At every iteration it finds actual source samples satisfying **both**:

```text
(sample_x-center_x)^2 + (sample_y-center_y)^2 <= spatial_radius^2
sum((sample_RGB-center_RGB)^2) <= range_radius^2
```

The spatial kernel is a circular disk; the RGB kernel is an ordinary Euclidean
ball. Their product is a flat joint spatial-color kernel. A clipped bounding
rectangle accelerates the search but does not replace the disk test. All
five coordinates are updated to the actual selected-sample means, using
`floor((sum + floor(support/2))/support)` independently. The next iteration
repositions the neighborhood around the updated spatial center and tests
color around the updated RGB center. All samples come from the captured
original frame; output pixels never overwrite the source model.

Integer centers and half-up means are the specified numerical variant.
Convergence means the maximum absolute movement of the five coordinates is
<= epsilon, after a complete update. Epsilon uses image pixels for spatial
coordinates and byte levels for RGB coordinates. Iteration count includes
the final update. At max_iterations the current mode is emitted even if not
converged, with `m_converged=0`. Integer rounding can create a cycle; the
iteration limit guarantees termination without falsely reporting convergence.
If support is empty, retain the preceding center, terminate with `m_empty=1`
and `m_converged=0`. This defensive path is implemented but was not encountered
in the finite valid-input fixtures and is not claimed tested by them.

WIDTH/HEIGHT support 1..32 each, at most 1024 pixels. START atomically captures:

- `cfg_spatial_radius`: 1..8 pixels.
- `cfg_range_radius`: 0..255; zero matches only exact current RGB. Radius 255
  does not include every possible RGB triplet (maximum RGB distance is >255).
- `cfg_max_iterations`: 1..255.
- `cfg_epsilon`: 0..255; zero requires exact integer-center stability.

Packed input/output is `{R,G,B}`. The output includes actual filtered RGB,
final spatial mode `m_mode_x/y`, completed `m_iterations`, `m_converged`,
`m_empty`, and `m_support`. Support describes the selected samples of the
last iteration **before** that iteration's mean update, not a new query at
the emitted mode. The filter is a frontend: it does not merge neighboring
modes into connected segment labels or provide region-merge postprocessing.
Means of valid bytes stay within 0..255, so no saturation/clipping is needed.

A complete frame is captured before any filtering. Image-border neighborhoods
include only actual in-frame samples: no padding or border replication.
The synchronous full-frame RAM has one serialized read address. Shared
8-cycle shift/add square arithmetic computes spatial/color distances and
radius squares; one shared 32-cycle divider updates the five coordinates.
This serial area-oriented engine has substantial frame latency and does not
claim one pixel per clock or video-rate throughput.

START, input and output transfers require CE and valid/ready. SOF marks only
the first input pixel, EOL every row end and LAST only the final pixel.
Output geometry and markers match the input. All per-pixel output fields
hold through CE stalls and backpressure. DONE follows consumption of the
final pixel and remains held until CE-qualified done-ready. Busy includes
pending DONE. `converged_pixels`, `limited_pixels`, `empty_pixels` are mutually
exclusive per-pixel categories; their sum at completion is WIDTH*HEIGHT.
They clear on every accepted START and hold after completion.

Active-low synchronous reset overrides disabled CE, cancels pending output
and completion and gates ready low. It is the explicit early abort. Frame
RAM is not cleared because the next frame overwrites all required locations.
Config input changes while busy do not alter the current operation.

Error 1 rejects invalid geometry, spatial radius or zero iteration limit,
accepting/emitting no frame and clearing aggregate counts. Error 2 records
SOF/EOL/LAST mismatch; N samples are still consumed, filtered and emitted
deterministically, followed by held error DONE. Discard that whole frame;
`m_empty` is a support condition and must not be mistaken for framing error.
Error 3 handles an invalid internal control state with held DONE. Missing
input samples wait for completion or reset. Acknowledging DONE permits a new
START without reset/reconfiguration.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/mean_shift/run_tests.py
python -B cores/system/common_scaffold/image/mean_shift/run_synthesis.py
```

The independent integer implementation enumerates real source coordinates
and computes exact means. RTL comparison covers all output RGB, mode x/y,
support, iteration/convergence/empty flags, markers and aggregate statistics:
54 completed frames / 6343 pixels, including 8 full healthy recovery frames.
Fixtures include thin/single-pixel images, constants, low-contrast/random
color, split regions, impulses, inclusive radius boundaries implicit in
enumeration, parameter extremes, early convergence, iteration limits, atomic
configuration, CE/backpressure, held DONE and all three marker errors.
Invalid START radius0/radius9/iteration0 is checked for every geometry.
Seven reset phases cover capture, original/candidate RAM, square arithmetic,
division, held output and DONE. A 32x32/radius8 first-pixel probe additionally
checks a real large disk and a spatial mode different from its initial pixel,
then resets held output and processes a complete healthy recovery frame.
The maximum-size whole-frame fixtures use radius1; no exhaustive 32x32 /
radius8 / 255-iteration throughput or convergence claim is made.

Actual OpenCV `pyrMeanShiftFiltering(...,maxLevel=0)` runs on all numerical
fixtures. Constants are asserted exact in both implementations. Other
observed discrepancies are preserved: maximum channel difference 49,
maximum per-frame mean channel difference 9.89524. OpenCV uses a rectangular
spatial window and different center/termination details, so these are variant
comparisons, not a claimed numerical error bound or image-quality guarantee.
The exact integer oracle is the normative reference (0 LSB discrepancy).
OpenCV segmentation.cpp and sklearn mean-shift sources were actually fetched;
URLs, UTC times, sizes and hashes are in `references.json`. No upstream code
was copied. No pyramid or generic sklearn clustering equivalence is claimed.

Isolated Gowin synthesis passes `check`: 7x5 uses 1215 LUT1..4, 119 MUX5,
601 FF and 18 RAM16SDP4; 32x32 uses 1191 LUT1..4, 101 MUX5, 641 FF and
2 DPX9B. Both use zero DSP and fit 15K LUT-class /4 DSP. This is not combined
system resource fit, routed timing closure or board acceptance. Temporary
testbenches, vectors, simulators and netlists are automatically cleaned.
`freeze_hashes.json` locks sources/scripts/docs; mutable reports have a
separate archival snapshot and can be refreshed by common regression.

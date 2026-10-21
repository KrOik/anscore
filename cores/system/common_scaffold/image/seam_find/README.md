# Minimum-cost stitching seam and feather mask

`seam_find.sv` consumes two aligned grayscale images of the same geometry and finds a minimum-cost, three-neighbor directed stitching seam. It performs full dynamic programming, stores predecessors, backtracks the selected path, and emits a complete raster mask for subsequent image blending. It does not remove pixels or perform seam-carving resize, and does not assume a middle cut.

## Interface

Runtime width/height are **1…32** (up to 1024 pixels). Commit `cfg_width`, `cfg_height`, `cfg_horizontal`, `cfg_gradient_weight` and `cfg_feather` using `cfg_valid && cfg_ready && ce`. `cfg_done` pulses for accepted configuration; `cfg_error` pulses for invalid geometry or feather >32, retaining the previous committed settings. Configuration has priority over START, is accepted only while idle, and cannot change during a frame. Uncommitted raw configuration input changes are ignored.

`start_valid && start_ready && ce` starts capture. Supply `s_a/s_b` together in raster order, with `s_sof` only on the first pixel, `s_eol` on every row end, and `s_last` only on the final pixel. Hold data and markers until `ce && s_valid && s_ready`.

After calculation and backtracking, `m_mask` streams the original frame geometry with `m_sof/m_eol/m_last`. `m_is_seam` identifies the single selected pixel per seam step. `m_valid` and payload are stable under backpressure and CE stalls. `seam_coordinates[6*i+:6]` is the transverse coordinate at step i; unused slots are zero. For vertical mode, i is row y and the coordinate is x; horizontal mode uses column x and coordinate y. `seam_length` is height or width accordingly. `total_cost` is the exact unsigned cumulative cost of that path.

`done_valid` asserts after the final mask pixel is accepted, holds all statistics until `ce && done_ready`, and allows another START after acknowledgement. `busy` covers capture through mask output. `abort` during an active frame drops pending mask validity and completes with error 3; discard any already emitted partial mask. Abort during held DONE is ignored. Acknowledging an error permits another START without reset or reconfiguration.

Synchronous active-low reset takes priority over CE and cancels capture, DP, backtracking, mask output or held DONE. It invalidates configuration. Frame/predecessor/DP RAM need not be cleared, since a new complete frame overwrites every address used by its calculation.

## Objective, boundaries and ties

For pixel `(x,y)`, let missing left/up neighbors equal the pixel itself. Define

```text
gx = (A[x,y] - A[x-1,y]) - (B[x,y] - B[x-1,y])
gy = (A[x,y] - A[x,y-1]) - (B[x,y] - B[x,y-1])
cost = abs(A-B) + gradient_weight * (abs(gx) + abs(gy))
```

`gradient_weight` is an unsigned **integer 0…255**, not a fractional parameter. The gradient is the difference between signed backward derivatives; it is not the difference of gradient magnitudes. Zero padding is not used. The cost is invariant under image transpose when vertical/horizontal modes are exchanged.

For vertical mode, a path has one x coordinate at every y, and adjacent x coordinates differ by at most one. Horizontal mode transposes that definition. Start/end coordinates are free. Out-of-frame predecessors are omitted. Equal-cost predecessors choose the **smallest predecessor coordinate**; equal-cost terminal pixels choose the smallest terminal coordinate. These local rules are equivalent to choosing the lexicographically smallest reversed path among equal-cost complete paths. A flat zero-cost frame therefore selects coordinate zero at every step.

Per-pixel cost is at most `255 + 255*1020 = 260355`, and a 32-step seam is at most **8,331,360**. Unsigned 18-bit pixel cost and 24-bit cumulative storage represent these values exactly; **no saturation is applied**. A defensive cumulative overflow check terminates with error 2 instead of silently wrapping.

## Mask convention

Let `d = transverse_coordinate - seam_coordinate` and `F=cfg_feather`:

- F=0: mask 255 for d≤0, mask 0 for d>0. The seam pixel belongs to image A.
- F=1…32: `mask = clamp(round((F-d)*255/(2F)),0,255)`, rounding to nearest with positive half ties upward. At the seam the mask is 128; at distance −F/+F it is 255/0.

Mask 255 selects A on the low-coordinate side; mask 0 selects B on the high-coordinate side. Feathering is a transverse linear ramp around each DP seam coordinate, not a Euclidean distance transform or a separate multiband blend. The output can feed `multiband_blend` as its per-pixel mask.

## Error behavior

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Input SOF/EOL/LAST mismatch |
| 2 | Defensive cumulative-cost overflow |
| 3 | Active-frame abort |
| 4 | Invalid internal state |

Invalid configuration uses the separate `cfg_error` pulse and does not begin a frame. Marker errors occur during capture before any mask output. All frame errors complete through held DONE; payload statistics are valid only for successful completion.

## Implementation and validation

Frame pairs, two alternating DP rows, and predecessor codes use clocked reads. Each pixel serially reads its center/left/up samples; an eight-cycle shift/add unit applies the gradient weight. DP predecessor reads are serialized, avoiding wide combinational frame access. Backtracking fills 32 six-bit seam registers. Feather conversion reuses a small sixteen-cycle restoring divider. Full frame memory plus traceback supports a true curved minimum-cost seam while remaining compact; this is a serial frame engine with no video-rate throughput claim.

Run from the repository root:

```powershell
python -B cores/system/common_scaffold/image/seam_find/test_seam.py
python -B cores/system/common_scaffold/image/seam_find/test_errors.py
python -B cores/system/common_scaffold/image/seam_find/synth.py
```

The main regression compares every RTL mask byte/marker/seam indicator, the complete coordinate vector, and total cost against an independent shortest-path oracle. Five small geometries also enumerate every admissible path. Eleven fixtures with one no-reset replay cover random data, maximum 32×32 geometry, gradient weights 0…255, feather 0…32, thin axes, transpose consistency, flat ties, and explicitly constructed curved zero-cost seams in both directions. The curved fixtures prove the result follows the data rather than a fixed cut.

Actual OpenCV `filter2D` with signed backward-difference kernels and replicated borders constructs the **same pixel cost field**, checked exactly for every fixture. Actual `cv2.detail_DpSeamFinder('COLOR')` also runs on offset overlapping images and its valid ownership masks are recorded. OpenCV's seam finder uses contour-selected terminals, component ownership and a different color-edge cost, so its masks are a conceptual implementation reference, not a claimed bit-equivalent golden for this specified free-terminal objective. OpenCV [seam_finders.cpp](https://github.com/opencv/opencv/blob/4.x/modules/stitching/src/seam_finders.cpp) was fetched/reviewed; URL, size and SHA256 are in `reference.json`. No external implementation code was copied.

Directed error tests exercise invalid configuration/retention, three marker errors, abort during capture/DP/backtracking/held output, CE-gated completion, successful DONE late-abort stability, and eight CE-low reset phases. Each is followed by a complete healthy recovery frame; all **15 recovery frames** match their golden mask, path and cost.

Full isolated Gowin synthesis and `check -assert` pass: **1659 LUT1…4, 653 FF, 1 DPB, 1 DPX9B, 24 RAM16SDP4, 0 DSP**, plus mux cells listed separately in `synthesis.json`. This satisfies the isolated 15K LUT/4 DSP target; routed timing, board validation and full-system fit remain separate work. The wide coordinate output is intended for internal integration, not direct physical board pin assignment.

All large simulation/synthesis artifacts are held in `TemporaryDirectory` and removed automatically. The directory retains only code, documentation, small JSON evidence and a synthesis statistics log.

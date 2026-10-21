# Four-plane RAW black-level correction

Original synthesizable full-frame RAW correction, default 32x24 / RAW8. Parameters WIDTH/HEIGHT accept 1..256 independently and BITS accepts 8/10/12. Input and output are one RAW sample per transfer, preserving frame dimensions and Bayer pattern. No host-precomputed statistics enter the RTL.

Manual mode uses four native-bit black levels. Auto mode captures one full frame into synchronous RAM while accumulating the configured optical-black rectangle independently for R, Gr, Gb, B. It then computes each mean by hardware 32-step restoring division, exact nearest half up: `floor((sum+floor(count/2))/count)`. Those same-frame means correct every RAW pixel during replay:

`output = clamp(raw - applied_black[plane] + target_pedestal, 0, 2^BITS-1)`

The host must select a rectangle that actually contains optically shielded pixels; RTL cannot infer whether sensor content is physically dark. Auto mode fails if the rectangle is empty/outside the frame, or any CFA plane has zero samples. A single-row/single-column image therefore supports manual correction but fails four-plane auto estimation explicitly. ROI coordinates are absolute full-frame sensor coordinates; CFA phase does not restart at the ROI origin. No ROI cropping occurs.

## Interface and statistics

START atomically snapshots all `cfg_*`. Pattern ABI is 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR. Packed `cfg_black_levels`, `stats_mean_levels` and `applied_black_levels` use R, Gr, Gb, B from least to most significant BITS-wide slice. Gr means green on the red row; Gb is green on the blue row.

`stats_sums` / `stats_counts` pack the same planes in four 32-bit slices. Manual mode reports zero sums/counts/means and the manual applied levels; it ignores ROI validity. Auto mode reports actual ROI statistics and computed means. `clip_low_count` / `clip_high_count` count *accepted output transfers* whose unclamped result was strictly below zero / above the maximum; equality with a boundary is not clipping. Successful DONE freezes all statistics until next START/reset. Statistics during processing or on error are partial diagnostics, not a successful calibration; some plane means may have been computed before a missing-plane error.

Every acceptance requires CE=1, including START, input, output and DONE. START/input ready are deasserted when CE=0; output valid/data/markers and DONE remain stable across CE pauses and backpressure. Reset is synchronous active-low and overrides CE; RAM contents are not reset. Abort immediately suppresses input/output acceptance, then reports error on the next enabled edge. Abort while already in DONE leaves the held result intact. After acknowledging an error, a new START captures a fresh whole frame.

SOF must occur only at pixel zero, EOL at every configured row end and LAST only at the final pixel. Invalid markers terminate capture immediately without replay. Errors: 0x80 invalid static specialization, 0x81 malformed input frame markers, 0x82 invalid auto ROI, 0x83 missing ROI CFA-plane samples, 0x93 abort, 0x94 illegal state. `done_valid` plus `done_error` makes errors explicit; successful DONE follows the final accepted output.

## Architecture and bounds

One synchronous frame memory, no asynchronous frame read and no memory clearing. Capture accepts one pixel per enabled edge. Auto means cost four times (initialization + 32 divide + result) enabled edges. Replay uses registered READ -> APPLY -> HOLD, at most one output every three enabled edges, with arbitrary sink pauses. This is a resource-oriented serialized engine, not a continuous one-pixel-per-clock video claim.

At maximum 256x256 RAW12, each CFA plane has at most 16384 samples and sum <= 67092480; 32-bit sums, counts and rounded numerators are safe. Signed BITS+2 correction range covers -4095..8190. The 33-bit trial remainder is explicit. No multiplier or combinational variable divider is used. Isolated default 32x24 synthesis reports RAW8/10/12 = 1560/1585/1618 LUT-class (including ALU/MUX and RAM16SDP4 x4), 1 DPX9B, 0 DSP; physical place/route and board timing are not claimed.

## Reproduction

Run from the repository root:

```
python -B cores/system/common_scaffold/image/raw_black_level/run_tests.py
python -B cores/system/common_scaffold/image/raw_black_level/test_protocol.py
python -B cores/system/common_scaffold/image/raw_black_level/test_parameters.py
python -B cores/system/common_scaffold/image/raw_black_level/synth.py
```

The integer/Fraction oracle passes 126 cases with 149064 accepted output pixels, including 21 expected-error cases. It checks exact pixels, all four plane sums/counts/means/applied offsets and clip counts, for manual/auto, all CFA patterns and 8/10/12-bit data; random offset ROIs, half ties, clipping, maximum data and geometry, thin dimensions, invalid ROIs and missing planes. Every case runs two frames with CE pauses, sink pauses, held DONE and live configuration corruption after START. The maximum 256x256 RAW12 case checks all four sums=67092480 and counts=16384, not just the final image. Protocol passes 12 healthy recovery frames / 192 pixels around abort in every active state, four SOF/EOL/LAST faults and reset with CE disabled. Five invalid-static-parameter cases exercise explicit failure. Evidence JSON binds current RTL SHA256. Temporary simulations/netlists are scoped to Python TemporaryDirectory and removed on completion.

Actual mature ISP source was fetched and inspected from Raspberry Pi libcamera; provenance/hash and precise differences are in references.json. It is a semantic tuning/control reference, not the numerical pixel oracle. This implementation does not copy libcamera C++ or claim libcamera RAW bit equivalence. No JTAG or UART was used for this module; board qualification is pending.

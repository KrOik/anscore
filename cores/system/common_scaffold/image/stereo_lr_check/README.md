# Stereo left/right integer-disparity consistency check

`img_stereo_lr_check` checks a complete, rectified pair of nonnegative integer
disparity maps. Repository search found a census matcher but no equivalent LR
consistency module. It flags inconsistent/invalid correspondences; it does not
estimate disparities, fill occlusions or improve image calibration.

## Geometry, convention and exact rule

Compile-time `WIDTH,HEIGHT=1..4096` with `WIDTH*HEIGHT<=65536`, `DISP_BITS=1..16`. Defaults: 8x6 pixels and
8-bit disparity. Disparities are **unsigned integer pixel counts**, not signed or
fixed-point values. The right map uses the positive magnitude from a right pixel
to its match to the right in the left image. Left pixel (x,y) with disparity d
therefore checks right coordinate `(x-d,y)`, and compares magnitudes directly.
Maps with a negative right-disparity convention must be converted upstream.

The original left disparity is always retained in `m_left_disp`, including invalid
outputs. The first applicable condition selects `m_reason[2:0]`:

| Reason | Condition | m_invalid |
| --- | --- | --- |
| 0 | All checks pass | 0 |
| 1 | Left input invalid flag is set | 1 |
| 2 | x-left_disparity is outside the row | 1 |
| 3 | The right map at that correspondence is invalid | 1 |
| 4 | abs(left_disparity-right_disparity) > frame threshold | 1 |

Priority is 1,2,3,4. Equality to threshold passes. With unsigned disparities,
out-of-bounds is equivalent to d>x, so no underflowed address is issued. The
absolute difference is formed by subtracting the smaller unsigned value from the
larger; it fits DISP_BITS exactly, including the full maximum disparity. A zero
disparity checks the same coordinate. Correspondences never cross row boundaries.

## Frame and configuration interfaces

Input pairs are `s_left_disp`, `s_right_disp`, `s_left_invalid`, `s_right_invalid`,
one paired coordinate per `s_valid/s_ready` transfer. Both maps must already be
aligned in raster order with `s_sof` on the first coordinate and `s_eol` on every
true row end. They must describe the same rectified frame; there is no independent
left/right timestamp synchronization in this block.

`cfg_valid/cfg_ready` commits `cfg_threshold[DISP_BITS-1:0]` while waiting for a new
SOF. Every value of that unsigned width is legal. `cfg_done` acknowledges for one
enabled cycle and holds during a CE pause. Configuration takes priority over input
when both are presented idle. Reset threshold is zero; no config is required to
run with that default. Threshold is snapshotted on the accepted frame SOF. Busy
configuration is not accepted or silently queued; a controller must keep it pending
until ready. New configuration cannot change an active frame.

After capturing both maps, output is `m_left_disp`, `m_invalid`, `m_reason`,
`m_valid/m_ready`, `m_sof/m_eol`, exactly WIDTH*HEIGHT coordinates per valid frame.
Output markers are regenerated from validated geometry. `done_valid/done_ready`
follows the last output transfer. Completion carries `done_error` and
`error_code[1:0]`: zero for success, one for malformed input markers. Per-pixel
invalid reasons are normal successful-frame results, not frame-processing errors.
New frame input/configuration waits until completion has been consumed.

All interfaces use `clk_en && valid && ready` on rising clock edges. Ready is low
while CE is disabled, reset asserted or the corresponding stage is busy. Output
and completion payloads remain stable under stalls/CE pauses. Consumers must use
the same CE-qualified transfer convention; sources hold pending payload until
accepted. There is no independent memory bus or external DDR adapter.

## Memory, latency and recovery

Two full-frame synchronous RAMs store disparity+invalid: logical storage is
`2*WIDTH*HEIGHT*(DISP_BITS+1)` bits. Neither RAM nor its read register is reset,
preserving block-RAM inference. A full replacement capture overwrites every
coordinate before processing, so stale RAM contents cannot become a valid frame.
Practical geometry is limited by available RAM; the parameter range is an
addressing limit, not a promise of device fit.

Capture accepts one pair per enabled edge. Processing reads the left entry, checks
validity/bounds, then synchronously reads the corresponding right entry if needed.
Without stalls, a left-invalid/out-of-bounds output takes 3 enabled edges per pixel;
a pixel requiring the right lookup takes 5. Input capture and output do not overlap
within one instance. First output appears after the full frame capture plus 2 or
4 enabled edges depending on whether a right lookup is needed. This is a serial
frame-checking engine, not a one-output-per-clock streaming matcher.

On a SOF/EOL mismatch the frame aborts with error completion before producing any
output. The offending sample is dropped, including an unexpected SOF. After error
completion is accepted, the next input must start a new legal frame SOF. A missing
SOF at initial/reset synchronization or recovery is also a fail-stop marker error
with error completion; no accepted sample is silently discarded.
There is no timeout for missing input pixels. Asynchronous low `rst_n` cancels
capture, processing, output or pending completion and resets threshold/config
state. Consumers must discard a partially received output frame on reset; no
transaction rollback or frame-ID tagging is provided.

## Reproduce and evidence

From repository root:

```powershell
python -B cores/system/common_scaffold/image/stereo_lr_check/run_tests.py
python -B cores/system/common_scaffold/image/stereo_lr_check/synth.py
```

Both scripts use `integration/tooling.py` for the actual OSS tool environment and
bounded execution. Simulator vectors/binaries and synthesis working files are
created in temporary directories and automatically removed; only small JSON/log
evidence remains in this directory.

The independent Python oracle calculates the full `(x-d,y)` correspondence and
reason priority, then checks every RTL result. Six profiles cover 1x1/1x9/11x1/
9x7/17x5/5x3 geometry with 1/4/8/12/16-bit disparities. Total 114 reference frames,
3496 samples cover all five reasons, zero/max disparity, exactly-equal thresholds,
maximum thresholds, thin rows/columns, invalid precedence, randomized maps and
flags, frame-boundary isolation, attempted busy config changes, random CE/source/
output stalls, payload/completion stability, malformed-frame/missing-SOF recovery and reset
during capture/processing/stalled output. The additional recovery frame is checked
numerically too. Missing-SOF fail-stop recovery is checked separately on every
profile. Parameter-boundary tests accept N=65536 and explicitly reject N=65792 at
elaboration. `test_result.json` binds this evidence to the current RTL hash.

`synth.py` uses `synth_gowin -noalu -nolutram` for 17x5, DISP_BITS=12. Isolated
mapping PASS / CHECK 0 problems: 188 LUT1..4, 32 MUX2_LUT5, 76 FF, 1 DPX9B +
1 SPX9, 0 DSP. `synthesis.json` includes exact cells and RTL hash, and
`synthesis.log` retains the tool output. No placement/routing, setup/hold or physical
stereo/JTAG validation was performed. Parent task owns shared manifest/runner
integration; no accepted legacy IP or shared source list was modified. The retained
`synthesis_pre_failstop.*` files document the superseded initial marker policy;
use `synthesis.json` and `synthesis.log` for the final fail-stop RTL.

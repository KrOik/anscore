# Generic 3x3 corner-score nonmaximum suppression

`img_corner_nms.v` captures a complete unsigned score map and emits an equally
sized score/corner map after 3x3 local NMS. Existing FAST9 explicitly produces an
unsuppressed score map; repository search found no equivalent corner NMS. Canny
gradient-direction suppression is a different operation and is not substituted.
The actual existing FAST9 RTL is exercised in the tests without editing it.

## Exact numeric and tie contract

Parameters: `BITS=8..32`, `WIDTH,HEIGHT=1..4096`, total pixels <=65536,
`KEEP_BORDER=0` or `1`. Invalid parameter values fail elaboration. Inputs and
comparisons are unsigned, including full 32-bit FFFFFFFF scores. No arithmetic
rescaling or signed interpretation is applied.

A center is eligible only when `score > frame_threshold` (strictly greater).
Thus threshold zero suppresses zero scores, and equality to any threshold is
suppressed. Compare each eligible center to every other in-frame pixel within a
3x3 neighborhood. Suppress it if any neighbor has a greater score, or the same
score and a smaller **raster index** (y*WIDTH+x). Otherwise retain the center.
The tie rule is local and deterministic; it does **not** claim one result per
entire arbitrarily shaped plateau or connected equal-score region.

`KEEP_BORDER=0` suppresses the outermost one-pixel frame border regardless of its
score. Thin WIDTH<3 or HEIGHT<3 frames therefore have no retained corners. Border
scores still participate as neighbors when checking an interior center.
`KEEP_BORDER=1` considers boundary centers and compares only in-frame neighbors;
there is no zero/replicate/mirror padding. A 1x1 positive score above threshold
is retained in this mode because it has no other neighbors.

## Interface, threshold and diagnostics

Input: `s_score[BITS-1:0]`, `s_valid/s_ready`, `s_sof` only at frame pixel0,
`s_eol` on every real row end. Output: original **unchanged** `m_score`,
`m_corner`, `m_reason[1:0]`, `m_valid/m_ready`, regenerated `m_sof/m_eol`.
Every valid frame produces exactly WIDTH*HEIGHT output samples, including
suppressed/background pixels. Filtering is indicated by the flag, not zeroing
the score or dropping the sample.

Reason priority and values:

| m_reason | Meaning | m_corner |
| --- | --- | --- |
| 0 | Retained local maximum | 1 |
| 1 | Score <= threshold | 0 |
| 2 | Suppressed frame border under KEEP_BORDER=0 | 0 |
| 3 | Greater neighbor or equal-score earlier-raster neighbor | 0 |

Idle `cfg_valid/cfg_ready` atomically commits unsigned `cfg_threshold`, default 0.
All values are legal. `cfg_done` acknowledges for one enabled cycle. Configuration
takes priority over idle input, is not accepted during a frame, and is snapshotted
on accepted SOF. A pending cfg request must wait for ready to affect a later frame.

After the last output transfer, `done_valid/done_ready` presents stable
`done_error` and `error_code[1:0]`: zero for successful processing, one for input
SOF/EOL mismatch. A missing initial SOF also reports an explicit error rather than
silently discarding the sample. Marker errors abort before any output because
validation occurs during the full capture phase. The offending sample is dropped;
after error completion is consumed, the next input must start a new valid SOF.
No missing-pixel timeout or automatic midstream SOF resynchronization is provided.

Transfers occur at rising clock edges with `clk_en && valid && ready`. Ready is
low during disabled CE, reset or processing/output as appropriate. Pending output
and completion data/markers remain stable under backpressure or CE pauses.
Both producer and consumer must obey this CE-qualified transfer convention.

## RAM, throughput and reset

Storage is one full-frame WIDTH*HEIGHT*BITS score RAM. The RAM and its read
register are not reset; all reads use one muxed address and a synchronous clocked
port. A complete replacement capture overwrites every score before output, so old
RAM contents cannot become a valid frame. Practical size is limited by device RAM;
the functional dimension range does not promise that every instance fits a board.

Capture accepts up to one sample per enabled edge. Output uses two enabled edges
to read/check its center and a final transfer edge. An eligible center visits
neighbors serially: three enabled edges per present neighbor (select/read/check),
one for an absent neighbor, with early exit on the first suppressing neighbor.
Thus an interior retained maximum takes up to 27 enabled edges including output
transfer, plus stalls. A threshold/border rejection takes three. No capture/output
frame overlap, line-buffer streaming or parallel max comparator is implemented.

Asynchronous low `rst_n` aborts capture, neighbor processing, stalled output or
pending completion, and restores threshold/config state. It does not clear RAM.
Consumers must discard a partially emitted frame after reset; there is no rollback
or frame-ID tagging. Tests that include FAST9 also clock reset through that older
module's synchronous reset interface.

## FAST9 connection and tests

The chain connects `img_fast9_frame.m_score/m_valid/m_sof/m_eol` directly into
this module's score stream, with properly coupled backpressure. FAST's score map
is computed independently of its own threshold flag, so NMS applies its own
explicit strict score threshold; the upstream `m_corner` flag is not used as a
second eligibility mask. In particular, score zero remains suppressed here even
if a FAST threshold convention could classify a strength-one point as a corner.

From repository root:

```powershell
python -B cores/system/common_scaffold/image/corner_nms/run_tests.py
python -B cores/system/common_scaffold/image/corner_nms/synth.py
```

The independent Python oracle enumerates complete neighborhoods and raster-index
ties. Ten profiles cover 8/12/16/24/32-bit scores, 1x1/thin/odd geometry, both border
policies, zeros/maxima, strict threshold equality, positive plateaus, checkerboards,
spikes and random maps. Eight direct profiles and two actual FAST9->NMS profiles
total 114 reference frames / 4471 output pixels. FAST score maps are calculated
independently from the radius-three circle and all 16 contiguous nine-pixel arcs;
bright/dark wrapped arcs and random imagery are included. The test compares every
score/reason rather than merely counting corners. Random source/link/output/CE
pauses, busy threshold attempts on direct input, stable payload/completion, missing
SOF/bad EOL recovery and capture/processing/stalled-output reset are exercised.
`test_result.json` records both final NMS and read-only FAST dependency hashes.

Scripts use `integration/tooling.py` with TemporaryDirectory workspaces; vectors,
simulator binaries and synthesis temporary files are automatically removed. Small
JSON/log evidence remains. The isolated 9x7,BITS32,KEEP_BORDER1 synthesis uses
`synth_gowin -noalu -nolutram` and reports CHECK 0 problems: 254 LUT1..4,
28 MUX2_LUT5 + 1 MUX2_LUT6, 126 FF, 1 SDPX9B, 0 DSP. `synthesis.json` and
`synthesis.log` describe the final single-read RAM. `initial_two_reads_synthesis.*`
retains the superseded mapping for traceability; it is not the current resource
claim. No JTAG, physical image-quality assessment, placement/routing or setup/hold
signoff is claimed. Parent task owns shared manifest and runner integration.

# FAST-9 frame corner detector

`img_fast9_frame.sv` implements the radius-three 16-pixel FAST circle with
at least nine contiguous samples strictly brighter or darker than the center
by the configured threshold. Arcs wrap around the circle. Nonmaximum
suppression is not implemented; every qualifying pixel is emitted.

For each nine-sample arc, strength is its minimum positive bright difference
or minimum positive dark difference. The largest arc strength determines
`m_corner = strength > threshold` and `m_score = max(0, strength-1)`.
The three-pixel border emits zero score and no corner. Images smaller than
seven pixels in either dimension therefore contain no detected corners.

Parameters: BITS is 8, 10 or 12; WIDTH/HEIGHT are positive and at most 4096;
WIDTH*HEIGHT must be at most 65536. Configuration is accepted before a frame
through cfg_valid/cfg_ready and persists across frames. Every handshake
requires `ce && valid && ready`. Active-low reset is synchronous.

Input s_data/s_valid/s_ready carries raster pixels with s_sof on the first
pixel and s_eol at each row end. Incorrect markers terminate the frame with
frame_error and no score output. Discard the remaining malformed frame,
acknowledge done_valid using done_ready, then send a fresh frame.
Output m_score/m_corner uses m_valid/m_ready and raster m_sof/m_eol.
Outputs and markers hold during stalls. done_valid is held until acknowledged;
frame_error identifies malformed capture. Reset aborts the current transaction.

The core captures the whole frame into synchronous RAM before processing.
Each interior pixel uses serial center/ring reads and 16*9 arc steps; this is
a resource-oriented frame processor, without a real-time video throughput claim.
Storage is WIDTH*HEIGHT*BITS plus 16 signed differences and control state.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/fast9/run_tests.py
python -B cores/system/common_scaffold/image/fast9/synth.py
```

Independent arc-oracle tests cover 26 frames / 1652 output pixels, strict
threshold equality, wrapped bright/dark arcs, eight-only rejection, random
transport stalls, malformed markers and reset. When OpenCV and NumPy are
installed, 18 additional 8-bit random images compare oracle coordinates with
OpenCV FAST_FEATURE_DETECTOR_TYPE_9_16 with nonmaxSuppression=False. This
cross-check passed with installed OpenCV 5.0.0. OpenCV is optional for the
RTL regression; its availability and result are recorded explicitly.

Isolated default 16x16/8-bit Gowin synthesis: 431 LUT1..4, 41 MUX5, 165 FF,
1 DPX9B, 3 RAM16SDP4, no DSP; check -assert PASS. Evidence:
`../../evidence/fast9_synth_20261018T182736Z_fa346adf`.
No board, timing, image-quality or large-resolution performance acceptance.

# Task status

Only new `image/disparity_reproject/` files changed. Full16-term4x4 Q homogeneous projection with signed subpixel disparity and exact XYZ/W;32-cycle shift/add multiplications,96-cycle restoring divisions, nearest-half-away rounding, explicit negativeW/zeroW/axis saturation and invalid handling. Atomic16-index Q commit, CE, output stalls, markers, reset and recovery are implemented.

Commands: `python -B .../run_tests.py`, `test_protocol.py`, `test_numeric_limits.py`, `synth_check.py`, `fetch_references.py`, `freeze.py`. Numerical15 frames348 points (all homogeneous sums and outputs), actualOpenCV837 finite components plusDecimal rational bounds, protocol3 config rejects3 marker errors5 resets4 complete recovery frames,17 parameter rejects: PASS. Synthesis default2874 / alternate2837 conservative LUT-class,0DSP,32 RAM16SDP4 counted as128 LUT equivalents, noBRAM. All source-based results bind exact RTL SHA256.

OpenCV4.12.0 stereo_geom.cpp retrieved and full reprojectImageTo3D implementation inspected; referenceSHA256 b8feb5ab5e63ea3deb87b56acf821399017c55547fc24ea4e9fdeee8458b15c4. Two earlier4.x requests timed out; pinned tag succeeded. Its intermediateVec3f-before-division rounding is explicitly covered by comparison error bounds. No code copied.

No temporary sim/synth/reference outputs remain (TemporaryDirectory cleanup). No PNR/timing/board claim. Root owns actualSGM→3D integration and shared registration. Register primarydisparity_reproject.sv; companion tests/synthesis live entirely in this folder.

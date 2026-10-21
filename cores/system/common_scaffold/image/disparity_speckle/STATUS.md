# Task status

Only new `image/disparity_speckle/` files changed. Implemented complete four-neighbor disparity-edge connected components with full N-entry BFS queue and <=size deletion, preserving original signed disparity and source-invalid/removed flags. Atomically latched per-frame threshold/size, synchronous single-write/registered-read memories, CE/markers/output stalls/done/reset/recovery are implemented.

Commands run: `python -B .../run_tests.py`, `test_protocol.py`, `test_numeric_limits.py`, `synth_check.py`, `fetch_references.py`, `freeze.py`. All PASS:18 frames1374 outputs,1358 actualOpenCV pixels;1config error3markers4resets5healthy recovery frames;11 invalid parameter sets. Tests bind exact current RTL SHA256.

Resource optimization replaced implicit multiport array accesses with one write/read port per memory. Final32x16/D24:1207 conservativeLUT-class,0DSP,DPX9B1+SDPX9B1,64RAM16SDP4 included as256LUT;conservative4BRAM9 units.64x32/D24:862LUT,0DSP,2DPB+5DPX9B,14BRAM9 units.31x17/D16:1642LUT,0DSP,2DPX9B,66RAM16SDP4,4BRAM9 units.

OpenCV4.12.0 filterSpecklesImpl retrieved via jsDelivr mirror after rawGitHub requests timed out; inspected four-neighbor per-edge disparity difference and count<=maxSpeckleSize rule. SHA256 c31cd2b73bdaf13cb01af2769372ea8a2af7c029301f13c3353f2fc0f6b6a32a. No copied code. Temporary sim/synth/reference files removed by TemporaryDirectory. No board/PNR/timing claim. Root owns shared registration and trueSGM→speckle→3D integration.

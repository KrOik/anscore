Completed genuine ordered cell-edge contour tracing, FG4/BG8, all loops/holes.
895 frames / 12989 pixels / 14468 edges / 2026 contours / 52 holes PASS,
independent edge-graph oracle plus actual skimage Euler/component audit.
Unified test_contours.py includes protocol tests: five CE0 reset phases,
full recovery, four invalid geometry cases. CE/stalls/DONE/markers PASS.
Isolated synthesis/CHECK PASS: default635 LUT1..4 / max-square570 LUT1..4,
0 DSP. No placed timing or board claim. All generated builds temporary.
Commands: python -B cores/system/common_scaffold/image/contours/test_contours.py;
python -B cores/system/common_scaffold/image/contours/synth_contours.py.
Changed files only inside contours directory; no shared or production edits.

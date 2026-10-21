Changed files confined to image/histogram_match/. No shared/old48/JTAG edits.
python -B test_histogram_match.py: PASS, seven profiles/56 frames/664 matched
pixels/51200 LUT entries, six illegal parameter sets. Independent big-integer
brute argmin and NumPy exact-object check; real interpolation difference logged.
Pending-reference deadlock identified in review was fixed; held request now
crosses remaining frame/processing/output/DONE and accepts next boundary.
python -B synth_histogram_match.py: PASS, two synth_gowin/CHECK profiles,
526/631 LUT1–4, 261/322 ALU, 501/607 FF, 4/23 RAM primitives, zero DSP.
No timing or board validation claim. Temporary build products cleaned.

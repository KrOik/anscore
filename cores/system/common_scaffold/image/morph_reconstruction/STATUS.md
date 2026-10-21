Changed only image/morph_reconstruction/; no shared/old48/JTAG modifications.
python -B test_morph_reconstruct.py: PASS six profiles/150 frames/2675 pixels,
four illegal static configurations. Exact simultaneous candidate/iteration/status
checks; actual skimage0.25.2 matches122 converged frames, rejects12 illegal pairs,
and bounds10 limited candidates. All op/connectivity combinations covered.
python -B synth_morph_reconstruct.py: PASS two synth_gowin/CHECK profiles,
307/374 LUT1–4, 123/175 ALU, 161/200 FF, 3/9 RAM primitives, zero DSP.
No board/timing/integrated budget claim. Temporary products cleaned.

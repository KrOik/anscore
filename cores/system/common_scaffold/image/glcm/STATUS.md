Changes confined to image/glcm/; no shared/old48/JTAG edits.
python -B test_glcm.py: PASS six profiles/48 frames/98304 matrix counts/192
exact feature records, nine illegal parameter sets. 168 matrices checked
against actual skimage0.25.2 graycomatrix; 84 nonempty feature records checked
against graycoprops. Independent scalar and NumPy pair oracles agree.
python -B synth_glcm.py: PASS two synth_gowin/CHECK configurations,
591/664 LUT1–4, 315/357 ALU, 378/426 FF, 2/3 RAM primitives, zero DSP.
No timing or board validation claim; temporary products cleaned.

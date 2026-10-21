# Task status

Only new `image/lens_shading/` files changed. Implemented independent R/Gr/Gb/B mesh maps, exact rational bilinear gain over full-frame endpoints, one final RAW multiply/half-up rounding/saturation, repository Bayer ABI0RGGB1GRBG2GBRG3BGGR. Double-buffer completeness mask/atomic commit supports inactive writes while processing, locked pending commit and swap only after frame acknowledgement/idle.

Commands: `python -B .../run_tests.py`, `test_protocol.py`, `test_numeric_limits.py`, `synth_check.py`, `fetch_references.py`, `freeze.py`. AllPASS:16 frames3771RAW outputs plus every weighted-gain numerator againstFraction;3config errors4marker errors4CE-disabled resets9complete healthy/recovery frames including real mid-frame next-map load/commit;14 parameter rejects49062weight-partition checks. Exact current RTL hashes bound all resultJSONs.

Synthesis default33x25 B12 mesh3x3:2122 conservativeLUT-class including20RAM16SDP4×4,0DSP/0BRAM.35x27 B10 mesh5x5:3058LUT-class,0DSP,DPX9B1/conservative2BRAM9units. No PNR/timing/board claims. Numerical maxRAW numerator<2^60 and denominator<2^44 cover all permitted parameters.

Retrieved matureRaspberryPi libcamera ALSC and inspected spatial resampleCalTable floor/phase/two-dimensional gain interpolation. SHA2564f7fc658085f0719bbe99e25fd25f3231c700c5978be9cb8939a79c2dd4dcd46. Its crop/meshgeometry differs, so no bit-identical source claim. Also inspected Infinite-ISP LSC, found execute returns unmodified input, explicitly excluded it as a functioning algorithm example. No copied external code.

Temporary simulations/synthesis/downloads cleaned automatically. Root owns shared registry and actuallens→Malvar integration. Primarysource lens_shading.sv; all companions in new directory.

# Task status

Only new `image/stereo_sgm/` files changed. Implemented actual four-cardinal Census SGM, synchronous descriptor/path/aggregate memories, exact integer recurrence and full disparity/score/invalid map. Existing WTA module and shared registries untouched.

Commands run: `python -B .../run_tests.py`, `test_protocol.py`, `test_numeric_limits.py`, `synth_check.py`, `fetch_references.py`, `freeze.py` (all within this directory). Functional/protocol/numeric/synthesis PASS. Functional10 frames510 outputs plus complete aggregate-volume comparison; protocol4 malformed4 resets2 complete recovery frames;11 parameter rejects. OpenCV implementation retrieved and recurrence inspected; documentation403 and paper404 are retained honestly in references.json.

Resources (LUT/ALU/MUX plus conservative RAM16 x4):8x6 D4 1579;16x8 D8 1265;32x16 D8 1288;all0DSP. No placement/routing or board claim. TemporaryDirectory cleanup removes all generated sim/synthesis/download assets. Only small source/evidence files remain.

Register primary stereo_sgm.sv, case directory stereo_sgm with run_tests.py and protocol/numeric/synth scripts. Root owns Census→SGM integration registration.

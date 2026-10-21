# Phase registration with actual aligned pixels

`phase_registration.sv` estimates a translation between paired grayscale A/B frames with the frozen `phase_correlation_frame` FFT engine, stores actual B pixels in synchronous RAM, and emits aligned B in raster order. SIDE is fixed at elaboration and supports 8, 16 or 32. This is integer circular translation; padding, subpixel interpolation and perspective correction are outside this module.

## Coordinate and stream contract

Output reads `B[(y-dy) mod SIDE, (x-dx) mod SIDE]`. For B made by rolling A down 2 and left 3, the returned displacement is dx=3, dy=-2. Exactly half a period maps to the negative displacement. Photometric differences in B are preserved in the emitted pixels.

START is accepted on an enabled `start_valid && start_ready` edge; `cfg_remove_dc` is sampled by the child at START. Input transfer requires CE, valid and ready. SOF marks only pixel zero, EOL each row end, LAST the final pixel. Output uses valid/ready plus regenerated markers; transfer requires CE as well. Synchronous B RAM uses explicit ADDRESS/READ/VALUE stages. This design has no one-pixel-per-clock throughput claim.

Successful DONE and result metadata remain held until an enabled DONE acknowledgement. After acknowledgement, another START needs no reset. Errors invalidate the entire frame, including any already emitted partial pixels. A marker mismatch terminates capture immediately: the caller need not finish supplying the malformed frame. Error DONE is held until acknowledgement; the child is reset in FAILED, allowing a subsequent healthy frame.

Abort suppresses output valid immediately, but the error transition is sampled only at CE=1. **Hold abort until an enabled edge; a pulse confined to CE=0 is not remembered.** Reset remains effective at CE=0. An abort after successful held DONE does not change the completed result.

Errors: `81` marker mismatch; `90` invalid/ambiguous phase spectrum; `40 | child_code` other child failure; `93` active abort; `94` invalid internal state. Failure metadata is not meaningful. Invalid spectra (too few bins, tied peaks or nonpositive peak) emit no pixels.

The default TWIDDLE_FILE is `twiddle.mem`. Integration must provide the frozen ROM from `../phase_correlation/twiddle.mem` in the working directory or override the parameter. Test/synthesis scripts copy it into automatically cleaned temporary directories.

## Verification evidence

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/phase_registration/test_registration.py
python -B cores/system/common_scaffold/image/phase_registration/test_errors.py
python -B cores/system/common_scaffold/image/phase_registration/synth.py
```

All PASS. Normal tests cover 7 actual frames at all three sizes, positive/negative half-period boundaries, no-reset repetition, source/output/CE stalls, configuration mutation after START and gain/offset B preservation. Independent recursive integer FFT checks exact metadata; NumPy FFT independently checks translation; every aligned pixel and marker is checked against a NumPy roll of B.

Error tests include 17 complete healthy recovery frames, malformed partial frames, zero/constant/periodic ambiguity with no output, capture/FFT/output abort, CE=0 abort held through CE=1, CE=0 reset in computation/RAM/output/DONE states, and held DONE behavior. See evidence.json and error_evidence.json for the frozen source hashes and results.

Full child hierarchy synthesis uses `synth_gowin -nodsp; check -assert; stat`. ALU and mux cells are explicitly included in conservative resource accounting:

| SIDE | LUT1..4 | ALU | LUT+ALU+MUX | FF | RAM | DSP |
|---|---:|---:|---:|---:|---|---:|
| 8 | 2320 | 1642 | 4139 | 1474 | 9 DPX9B + 8 RAM16SDP4 | 0 |
| 16 | 2349 | 1653 | 4185 | 1510 | 10 DPX9B | 0 |
| 32 | 2368 | 1665 | 4213 | 1530 | 10 DPX9B | 0 |

These are synthesis results, with no routing, timing or physical-board acceptance claim. Child algorithm references and provenance remain in `../phase_correlation/references.json`.

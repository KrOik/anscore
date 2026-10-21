# Frozen status

Implemented and locally verified: true forward 2D FFT A/B, conjugate crosspower,
real complex-magnitude square root normalization, inverse 2D FFT and circular
integer translation. All changes are exclusive to this directory. No shared
files, existing cores, JTAG or serial ports were modified/accessed.

Commands completed successfully:

```powershell
python -B cores/system/common_scaffold/image/phase_correlation/run_tests.py
python -B cores/system/common_scaffold/image/phase_correlation/synth_phase_correlation.py
```

Final revised-RAM simulation: PASS, 113.688 seconds while synthesis ran in
parallel. 20 main frames / 3584 paired pixels over SIDE8/16/32, exact recursive
integer FFT oracle; actual NumPy and OpenCV checks agree on all unambiguous
displacements. Gain/offset, circular wrapping, zero spectra, constant/periodic
ambiguity and all four marker errors are included. CE pauses occur during
arithmetic as well as input/result/DONE. Ten phase resets at CE=0 each recover
with a healthy frame; six invalid parameters are rejected. All PASS.

Full isolated synthesis plus `check -assert`: PASS for all supported sides.
LUT1..4 2210/2235/2250; ALU1617/1619/1622; FF1375/1385/1395; DPX9B×9; DSP0.
This includes the entire arithmetic and all coefficient RAM banks. The earlier
RAM-address structure was stopped during synthesis due to register expansion;
final evidence applies to the corrected shared physical-port address structure.

RTL SHA256: `473b9692f387683afc5c4d9d5c5a4fcc3fc78ba909f9e6ffa1b1e481af5707bf`.
Other frozen sources/assets are hashed in `freeze_hashes.json`. Source fetches
from OpenCV, NumPy and scikit-image succeeded through direct network access;
actual hashes/timestamps are retained. Temporary build/simulation artifacts
were cleaned automatically; only small source/ROM/evidence files remain.

No subpixel, nonperiodic-border, routed timing or board validation claim.

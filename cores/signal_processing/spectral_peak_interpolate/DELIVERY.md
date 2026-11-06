# B47 delivery: fractional spectral peak location

New capability: a framed FFT power instrument selects the earliest strongest
in-band bin, reads its actual neighbors and returns a three-point parabolic
Q16 frequency-bin location. It qualifies local concavity/threshold/energy and
reports exact powers/curvature. The real signed16 I/Q example uses unchanged
`mag_squared`; unchanged `peak_search` and `fp_div_iter` perform the actual
selection and RNE division. Mature sources were not modified.

**LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**, limited to the frozen finite
profiles. Icarus syntax checking is the LINT_PASS evidence. No synthesis,
PnR, STA, board, device-fit, measured power or PPA work was performed.

Exact once-only receipt:
`reports/20261106T152538_080888Z/results.json`
SHA256 `a34ca8cc9fd3cef14c29df074a66120182cba9e225c2264e86de48806faf4061`.
Four preparation children and ten HDL children all passed: two syntax,
four compilations and four simulations. There were184 exact responses,
736 held-output cycles and56 live reset cancellations with56 successful
recoveries. Each profile observed adjacent-clock accepted samples.

The executed source, plan, seal, root/peer review, original raw evidence,
vectors and child records remain frozen. Four original VVP images are retained
under ignored `.build/`, outside the formal deliverable. No failure or retry
occurred. `QUALIFICATION.json` and `QUALIFICATION.md` describe the evidence
and its limits; authored README/manifest remain the original execution inputs.

The estimator uses linear power and can have window/noise/multiple-tone bias.
It does not automatically identify a fundamental or replace a complete FFT,
frequency calibration or physical instrument qualification.

# Provenance and semantic review

Production RTL, example, testbench, runner and documentation were independently
authored for ANSCORE under Apache-2.0 (repository `LICENSE`). No external source,
table, dependency, generator, helper executable or model was imported.

Prior-art and technical review was performed read-only on 2026-11-06 (Asia/Shanghai):

- RadarSimPy `cfar_ca_1d`:
  https://github.com/radarsimx/radarsimpy/blob/master/src/radarsimpy/processing.py
  documents guard/training cells on each side and local cell-averaging thresholds.
  The repository's `LICENSE` was read before implementation:
  https://github.com/radarsimx/radarsimpy/blob/master/LICENSE (GPL-3.0).
  This is a mathematical/behavioral reference only; its convolution, edge padding,
  floating-point PFA calculation, source and license text are not copied here.
- External project discovery also inspected
  https://github.com/tooth2/2D-CFAR/blob/master/README.md . Its LICENSE endpoint
  returned 404, so it was not eligible for source adoption and none was imported.
- The primary MathWorks `phased.CFARDetector` documentation endpoint returned
  HTTP 403; it provides no evidence claimed by this delivery. The session web
  search endpoint returned HTTP 500, after which the read-only upstream pages
  above were retrieved directly.

The independently specified predicate is
`sample * denominator * number_of_reference_cells > sum * numerator`.
Runtime alpha avoids copying a probability/threshold lookup. Incomplete windows
are explicitly ineligible rather than padded, and all arithmetic is exact
integer arithmetic. The finite TB uses an independently enumerated neighborhood
definition and no external scientific package.

Internal semantic review checked `dsp_isp_library/dsp/goertzel` and
`operator_library/rtl/acc_goertzel_dtmf.v` before declining a duplicate Goertzel
implementation. `dsp_isp_library/dsp/spectrum` supplies power conversion and
block maximum search but no local guard/reference-window threshold detector.
Repository searches for `cfar` and `constant.false` in RTL and README files
found no existing implementation before this package was added.

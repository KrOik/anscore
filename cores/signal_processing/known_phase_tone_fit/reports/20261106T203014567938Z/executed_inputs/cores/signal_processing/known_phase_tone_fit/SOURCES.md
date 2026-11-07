# Sources, reuse, and differentiation

The package is authored under the repository's Apache-2.0 license. Its LICENSE
is a byte copy of the root LICENSE. Two unchanged in-repository source files are
compiled through relative paths and instantiated exactly once each:

| Source | Bytes | SHA256 |
|---|---:|---|
|`cores/acceleration/stream_sincos/rtl/stream_sincos.sv`|5483|`b0945b83dded63e7eee0b3beb87c93bf4787f862273915f0f5193336efd8a2cf`|
|`cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v`|2016|`40e6dffb4b0c87a5ee71e414ced900cd2ebf6019013a043261c7a2a47a9de60f`|

No external RTL, generated IP, network retrieval, package download, or local
site-specific include is needed to compile the package. Runtime tools are pinned
separately in FINITE_PLAN.json. The lifecycle runner is source-adapted from the
frozen B49 fft_overlap_save_fir runner; B49 files and evidence remain untouched.

A read-only dedup pass examined approximately1839 production-candidate RTL files
under cores, omitting test/build/archive copies. Nearby implementations were
read at their real interfaces: lockin4, DDC, Goertzel, correlation, statistics,
BPSK Costas carrier loop, stream_linear_fit, nonnegative_least_squares2,
fixedpoint_ldlt, and linear_solve2x2. The existing ordinary lock-in at
`cores/signal_processing/lockin/rtl/lockin4.v` already offers four signed16
channels, DDS, power-of-two boxcar windows16..4096, calibration, timestamps,
I/Q and amplitude/phase. The new block instead fits a supplied per-beat phase
over arbitrary N3..256 with an unknown DC offset and finite-window cross terms.
It neither duplicates nor replaces that ordinary lock-in interface. The existing
2x2 solver has W<=24 and was not forced into this wider Gram domain.

Primary technical background, read before drafting:

- [Zurich Instruments, MFLI signal-processing basics](https://docs.zhinst.com/mfli_user_manual/signal_processing_basics.html)
  describes mixing and low-pass filtering for ordinary lock-in I/Q measurement.
- [NIST, Linear Least Squares Regression](https://www.itl.nist.gov/div898/handbook/pmd/section1/pmd141.htm)
  explains models linear in their unknown coefficients and least-squares fitting,
  including sinusoidal predictor terms.

Those pages establish background only. The DC elimination equations, exact
quantized-basis contract, width proof, serial schedule, and resource estimates
are package design derivations; the pages do not provide this RTL or qualification.

The independent fit oracle solves the full3-column normal system with Fraction
Gaussian elimination, not the RTL centered2x2 Cramer schedule. Gram diagnostics
use pairwise differences, and the common denominator uses a3x3 determinant.
The CORDIC dependency is represented by an explicitly labeled integer bit model
with independently regenerated Decimal constants and an ideal-trig check for
each used phase. This is not independent requalification of the dependency RTL.

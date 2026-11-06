# Source, semantic and license audit

Baseline `a0602fb2dac20db7c524297371a19f5f580980df`, B45.
All new implementation and integer/Fraction reference code were independently
written as repository-native Apache-2.0. LICENSE is an exact raw copy of the
repository license. No upstream implementation was copied, imported,
installed, built or executed.

Before development, a whole-repository `rg --hidden --no-ignore` text search
including archives, reports and unindexed material found no bicoherence,
bispectrum, third-order spectrum, quadratic phase coupling or 双谱/三阶谱
capability. Related actual RTL/interfaces/documentation were inspected:

| Existing service | Boundary |
|---|---|
| dsp_isp_library/dsp/correlation | Uploaded runtime template, sliding full/valid correlation and argmax; already overlaps a general lag correlator |
| acquisition/micarray_doa | Actual lag-scanned MACs and best-delay extraction for microphone pairs; the proposed new multi-lag delay service was therefore rejected |
| repeated_half_sync | One-stream adjacent repeated-half relation and coarse burst event; second-order relation |
| paired_spectral_coherence | Two spectra and normalized second-order cross sum; no multiplicative third frequency |
| spectral_kurtosis | Per-bin power moments across frames; discards complex cross-frequency phase |
| spectral_harmonic_quality | Within-frame spectral power masks and ratios; no ensemble cubic complex sum |
| phase_allan_variance | Existing phase/frequency stability measurement; also excluded as a new topic |

Actual unchanged dependencies, complete offline source closure:

| Repository source | Raw SHA256 |
|---|---|
| cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v | 40e6dffb4b0c87a5ee71e414ced900cd2ebf6019013a043261c7a2a47a9de60f |
| cores/acceleration/integer_divider/rtl/integer_divider.v | e09b6e9501a02fbcb0a89be50b5a0b787c71e9180b934b32d446601a299c5f6c |

The new core instantiates both dependencies. The example instantiates the
core and supplies measured bins from each accepted spectrum frame. Source
lists resolve the complete closure without a network or generated HDL file.

## Read-only upstream references

The primary upstream [PyBic source](https://github.com/rigzridge/pybic/blob/c11097a9735039600adff30c7da972621c2d0d2c/pybic.py)
was read at commit `c11097a9735039600adff30c7da972621c2d0d2c`.
Its GetBispec routine documents the complex triple product and normalization
by the two summed energies. UTF8 response166317 bytes,
SHA256 `edf2145753281ae51f9d9ff9c869c82bbcb9b7e04cd8810d09084f9729d9d641`.
The [upstream license](https://github.com/rigzridge/pybic/blob/c11097a9735039600adff30c7da972621c2d0d2c/LICENSE.md)
is GPL-3.0, response35127 bytes, SHA256
`7fa7e56c0db71105f4b59a6a0ac40225eb059876f85cd380383f7d7a066e68be`.
This was a mathematical/semantic reference only. No PyBic source, NumPy,
plotting code, randomized analysis or license text is redistributed.

This core uses exact integer sums and exact zero-energy status instead of
an epsilon-adjusted denominator. Its B output is the raw sum; the upstream
also supplies a subsequently averaged bispectrum. No randomization,
bootstrapping or interpretation beyond the defined finite statistic is used.

Additional primary read-only checks inspected Stingray v2.2.5 bispectrum.py
and its MIT license, SciPy v1.14.1 correlate documentation/BSD license, and
GNU Radio v3.10.11.0 corr_est_cc_impl.cc/GPL-3.0-or-later. Their roles were
semantic differentiation from lag correlation and indirect third-order
cumulant methods. None supplies executable dependencies to this package.
PyBispectra's official repository was located but its alternative estimators
were not used as this arithmetic contract. Some candidate raw URLs returned
404 and were excluded as sources. `web.run` search returned infrastructure
HTTP500; official GitHub API and fixed raw URLs were read by HTTPS instead.

No preflight search executed a project model or helper. Source development
performed no numerical preparation or HDL checks; plan, TB and reference
remain unexecuted until an independent exact-source gate.

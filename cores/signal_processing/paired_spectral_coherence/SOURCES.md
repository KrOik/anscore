# Sources and reuse — B36

Baseline: `8ba6835fe51ad285b926cd24e3ba4d172aefce26`. New RTL, connecting example, TB and Python mathematical oracle are original ANSCORE work under repository Apache-2.0 / root `LICENSE` and `NOTICE`. No external implementation was copied, translated or executed.

The following existing ANSCORE helpers are used at their original repository paths, with original bytes and interfaces:

| Canonical source | Role | SHA-256 |
| --- | --- | --- |
| `cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/cplx_mac.sv` | Signed17 complex products; ACC_W35, OUT_W33, SHIFT0 | `21f17250725762362f70e9d9c3f7165a6c3bc52326c45696bccafb097e37f4fd` |
| `cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv` | `fp_div_iter`, exact positive ratio, FB16/OUT_W18 | `280d4aa40ca513befb76ef3dae03cf32e88b773c5cefcf526b8c9cfb89e1d3cb` |
| `cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v` | Exact shared unsigned square/product with CE tied1 | `40e6dffb4b0c87a5ee71e414ced900cd2ebf6019013a043261c7a2a47a9de60f` |

These are existing repository Apache-2.0 contributions covered by `NOTICE`. They are not newly authored external imports. Their mature evidence is not inherited by this combination. The divider was already in the B35 canonical support closure; root integration adds the two other existing canonical paths. `recip_div.sv` also declares unused `fp_div_pipe`; it remains unmodified. `files.f` and `example/files.f` are package-root-relative lists and require no generated ROMs, downloaded packages, vendor primitives or network access.

Read the helper implementation for lane packing: the actual `cplx_mac` lane order is `{b_im,b_re,a_im,a_re}`. Its first header summary line is inconsistent with its explicit lane slices. The new core follows those actual slices and tests the sign of `Conj(X)*Y`. The MAC and divider have synchronous active-low reset; the serial multiplier has asynchronous active-low reset and a CE-qualified interface. The core explicitly bridges those reset semantics and ties the serial multiplier CE high. No helper source was edited to normalize these contracts.

Pre-implementation read-only reference was SciPy **v1.16.2**, specifically [`coherence` and `csd` in `_spectral_py.py`](https://github.com/scipy/scipy/blob/v1.16.2/scipy/signal/_spectral_py.py), with the upstream [BSD-3-Clause license](https://github.com/scipy/scipy/blob/v1.16.2/LICENSE.txt) reviewed. The public magnitude-squared coherence relation is `abs(Pxy)^2/(Pxx*Pyy)`, and the cross convention is `Conj(FFT(X))*FFT(Y)`. Only the formula/convention informed the independent design. No SciPy source, script or dependency is imported or executed by this package; the oracle uses Python standard-library integer arithmetic and `Fraction`.

Pre-implementation semantic comparison found no complete equivalent: `dsp_isp_library/dsp/correlation/rtl/correlation_stream.sv` supplies time-domain sliding template correlation and lag/argmax; `common_scaffold/image/phase_correlation` supplies single-pair 2D phase correlation for image displacement; `lockin4` supplies reference-synchronous integrators; `stft_welch` supplies single-channel power averaging and discards relative phase. Existing spectral-band, occupied-bandwidth and CFAR paths supply scalar-power measurements. Paired multisegment per-bin cross-spectrum and magnitude-squared coherence is the independent functional increment.

The finite receipt and its source archive retain all three actual helper files alongside the original sources, file lists, TB and runner. They are evidence copies; active compilation uses only the original canonical repository paths. Source hashes in `B36_DELIVERY.json` and the receipt bind the numerical/vector preparation and HDL results to those exact bytes.

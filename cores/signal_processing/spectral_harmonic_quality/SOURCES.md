# Provenance and semantic gap

New RTL, wrapper, model, TB, runner and documentation are original ANSCORE
Apache-2.0 contributions under the repository LICENSE/NOTICE. No external code,
generator, coefficient table or executable is imported or executed.

Read-only official upstream review before implementation on2026-11-06:

- Repository: https://github.com/endolith/waveform-analysis
- Fixed commit: `6bfa59ba518d50a8ff40c8a426ab8d9ceda0f43a`.
- Source: https://github.com/endolith/waveform-analysis/blob/6bfa59ba518d50a8ff40c8a426ab8d9ceda0f43a/waveform_analysis/thd.py
  (`THD` and `THDN`). Inspected spectral harmonic-power summation, fundamental
  versus original-signal normalization and the strongest-fundamental assumption.
  Git blob `ee5083e4c908cafd65a84c8bc2e4cc7518f2a3f0`,9107 bytes,
  SHA256 `e0941bfebc754aaaccf523bba3db04854805fcca08a7795fc63e1a7d0d3a4c5c`.
- License: https://github.com/endolith/waveform-analysis/blob/6bfa59ba518d50a8ff40c8a426ab8d9ceda0f43a/LICENSE.txt .
  MIT, copyright2016 endolith@gmail.com; inspected before authoring.
  Git blob `45cde0c9b4054dd676156b40197f0d65ba621a23`,1085 bytes,
  SHA256 `c2cd06039249a8d682206990543a78a29845d11cc3e2c72cccf10886cdc9721f`.

This is an independent exact discrete-bin FPGA definition. It does not copy
the upstream flat-top window, interpolation, coefficient selection, inverse
FFT, A weighting or floating-point implementation and does not claim to match
that analyzer numerically. Fixed nonoverlapping integration windows replace
single-bin amplitude extraction; all definitions and limits are in README.

Semantic search covered actual RTL and README/SPEC under canonical signal
processing, common_scaffold signal/video and legacy operator packages for
harmonic, THD, SNR, SINAD, SFDR and distortion, followed by actual source review:

| Existing source | Actual capability and reuse decision |
| --- | --- |
| dsp_isp_library/dsp/spectrum/rtl/peak_search.sv | One u32 global max/earliest tie; reused on a masked complete spectrum. No harmonic classification. |
| spectral_band_monitor/rtl/spectral_band_monitor.sv | Runtime overlapping arbitrary bands with sums, moments and peaks; reused unchanged after the selected peak determines separated harmonic windows. |
| occupied_spectral_bandwidth/rtl/occupied_spectral_bandwidth.sv | Equal-tail cumulative-power interval; preserve, no harmonic or residual power ratios. |
| dsp_isp_library/dsp/stft/rtl/stft_welch.sv | FFT/window/power and averaging frontend; preserve. This instrument consumes a complete power spectrum. |
| block_ca_cfar and symbol_evm_measure | Detection threshold/local reference EVM; preserve, neither partitions FFT power by harmonic order. |
| common_scaffold/image/stereo_subpixel/stereo_subpixel.sv | Existing exact quadratic WTA interpolation; rejected sub-bin interpolation as a duplicate direction. |
| dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv | Actual signed16 I/Q to exact u32 power, reused in the real example with its global-stall protocol. |
| dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv | Existing full-remainder RNE iterative division, reused serially for three instrument ratios. |

The functional increment is the automatically selected fundamental, derived
harmonic masks, exact disjoint classification, explicit residual semantics and
linear quality ratios under one framed command. Existing integrations are
retained rather than cloned. No claim of mathematical novelty is made.

The four canonical helper files remain at their original tracked paths, with
unchanged bytes. PRECHECK_SEAL and the executed-input archive bind their exact
raw hashes to this qualification. No old test or implementation result is
claimed to cover the new combination. The old band monitor's extra moment
arithmetic remains present; eliminating it would require modifying a shared
asset and is outside this package's scope.

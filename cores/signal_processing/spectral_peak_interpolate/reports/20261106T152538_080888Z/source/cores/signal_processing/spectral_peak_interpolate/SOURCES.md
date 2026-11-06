# Read-only provenance and semantic boundary

Reviewed2026-11-06. New RTL/model/TB/control are independently authored;
external code is not imported or translated. New files use Apache-2.0.

1. Julius O. Smith III, *Spectral Audio Signal Processing*, author book chapter
   [Quadratic Interpolation of Spectral Peaks](https://www.dsprelated.com/freebooks/sasp/Quadratic_Interpolation_Spectral_Peaks.html),
   HTTP200 read-only. It derives the three-point vertex formula
   p=(yp1-ym1)/(2*(2*y0-yp1-ym1)). The local parabolic model motivates the
   new operation. Our interface explicitly applies it to linear power.
2. The same author's
   [Bias of Parabolic Peak Interpolation](https://www.dsprelated.com/freebooks/sasp/Bias_Parabolic_Peak_Interpolation.html),
   HTTP200 read-only, explains window-model bias. This package makes no
   Gaussian/dB exactness or universal unbiased-frequency claim for power input.
3. External open-source discovery also attempted aubio's upstream mathutils
   and generated documentation: GitHub raw TLS failed and three documented
   endpoint attempts returned404. No aubio implementation was obtained or used.
   The web search connector returned an upstream500; the two author-book
   chapters were obtained by direct read-only HTTPS instead. No source/project
   code was executed during this search.

Production README/RTL semantic searches for parabolic/quadratic spectral peaks,
peak interpolation, fractional bins and frequency estimators found no existing
sub-bin spectral-peak instrument. Directly reviewed boundaries:

| Existing asset | Existing result and difference |
| --- | --- |
| dsp_isp_library/dsp/spectrum/rtl/peak_search.sv | One integer maximum/index; no neighbor fit |
| spectral_band_monitor | Band sum, moment, peak and occupancy; no fractional peak |
| spectral_harmonic_quality | Integer fundamental search, harmonic power windows and ratios; no sub-bin vertex |
| block_ca_cfar | Local adaptive detection for all cells; no peak location fit |
| goertzel_bank | Selected-frequency response; not interpolation of a loaded FFT frame |
| dsp_isp_library/dsp/farrow | Cubic sample interpolation already exists; not selected for B47 |

Real unmodified dependencies (all under cores/signal_processing/dsp_isp_library):

| Path | BASE d32ea87e268c5957b7203560a5b46864e282a6e1 blob OID, root verified |
| --- | --- |
| dsp/spectrum/rtl/peak_search.sv | 8981be5b0caef121107cdc2327e0eaa382c0e13c |
| dsp/spectrum/rtl/mag_squared.sv | 35012a14f1f491405f3edc3d2a191538751ad972 |
| infra/fixedpoint/rtl/recip_div.sv | 4ec5fddeca14093b329f538f87a208541a52a5db |

The canonical root SHA256 hashes are pinned in the finite plan and seal.
No mature dependency, package metadata, external repository or shared source
is changed. This is an engineering novelty boundary, not a patentability claim.

# Source and semantic review

Baseline: `09de72c578b3099d4e867c739118faa7607f663d` (B44).
New implementation is repository-native Apache-2.0 source. The repository
LICENSE was copied as raw bytes. No third-party implementation was copied,
imported, installed, built or executed.

The development precheck searched the whole `cores` tree with
`rg --hidden --no-ignore`, including unindexed archives/candidates, for spectral
kurtosis, kurtosis, fourth/power moments and Chinese 峰度 terms. No equivalent
estimator was found. Related actual interfaces/RTL and documentation were read:

| Existing capability | Semantic difference |
|---|---|
| paired_spectral_coherence |two spectra, complex cross sums and normalized relation; no fourth-power variability of one stream|
| spectral_harmonic_quality |one spectrum, fundamental/harmonic masks and band ratios; no time batch per bin|
| spectral_band_monitor |within-spectrum bin aggregation and peak/centroid; no per-bin cross-frame state|
| chi_square_gof |observed/expected category counts, per-term rounding and common-mass checks|
| stream_integer_moments |one framed scalar reduction, extrema and raw moments; no interleaved-bin RAM or corrected SK ratio|
| stream_cross_moments |bivariate raw sums, no normalized univariate spectral variability|

Existing arithmetic and power interfaces were read before selection. The new
RTL reuses three unchanged dependencies, with no mature shared RTL edit:

| Dependency | Baseline Git blob |
|---|---|
| cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v |4b2aa7bc204d1a51d9d5250695fcf6aa03bbf481|
| cores/acceleration/integer_divider/rtl/integer_divider.v |1fc5b587f6b5aefd713aa8585bfa107708997bab|
| cores/signal_processing/dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv |35012a14f1f491405f3edc3d2a191538751ad972|

The source lists retain the complete offline closure through these repository
paths; all three are archived as raw inputs before any preparation/check.

## Read-only primary references

The LWA Software Library official repository was read at fixed commit
`2a47cce0e421c239971f6a81d9403dcd94256b86`:

- [kurtosis.py](https://github.com/lwa-project/lsl/blob/2a47cce0e421c239971f6a81d9403dcd94256b86/lsl/statistics/kurtosis.py)
  defines unaveraged FFT power SK and the generalized N-averaged normalization.
  UTF8 response4,583 bytes, SHA256
  `3b1ea01b057fb3847ab2ccea44983b0befa38967a21e85333817ec59e680b811`.
- [LICENSE](https://github.com/lwa-project/lsl/blob/2a47cce0e421c239971f6a81d9403dcd94256b86/LICENSE)
  is GNU GPL version2. UTF8 response18,092 bytes, SHA256
  `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643`.

These files were technical references only. Their NumPy/SciPy implementation,
distribution fitting and confidence-limit code are neither redistributed nor
executed. The RTL and exact integer/Fraction oracle were independently written
from the mathematical estimator; no external runtime dependency is required.

Crossref primary metadata confirmed Nita and Gary, *Statistics of the Spectral
Kurtosis Estimator* (2010), [DOI10.1086/652409](https://doi.org/10.1086/652409).
The formula in this package is specifically the unaveraged N=1 normalization.
No theorem-derived detection thresholds, fitted distribution or confidence
interval is implemented. The external reference's different generalized cases
are deliberately outside this package's contract.

`web.run` search returned an infrastructure HTTP500; the official GitHub API,
fixed raw URLs and Crossref metadata were retrieved read-only by HTTPS instead.
No upstream source was stored as an executable local file.

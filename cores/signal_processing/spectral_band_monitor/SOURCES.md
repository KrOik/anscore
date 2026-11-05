# Provenance, reuse and semantic gap

New monitor RTL, wrapper, testbench, reference/runner and documentation are
original ANSCORE Apache-2.0 contributions, covered by the repository LICENSE and
NOTICE. No third-party source, table, generator or executable was imported.

Read-only primary/upstream review before implementation on2026-11-06:

- SciPy periodogram documentation:
  https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.periodogram.html .
  Spectrum versus density units informed the explicit bin-spacing/normalization
  boundary; no SciPy routine or FFT implementation is executed or copied.
- MNE-Features upstream `compute_pow_freq_bands`:
  https://github.com/mne-tools/mne-features/blob/master/mne_features/univariate.py .
  Reviewed the existing frequency-band power feature as an instrumentation use.
- MNE-Features license:
  https://github.com/mne-tools/mne-features/blob/master/LICENSE .
  BSD-3-Clause terms and MNE-Features copyright were inspected before authoring.
  No source or license text was adopted; this original implementation defines
  exact unsigned bin-index sums and a streamed FPGA command contract.

Deep internal review found:

| Existing asset | Coverage | Decision |
| --- | --- | --- |
| dsp_isp_library/dsp/stft/stft_welch | Overlap/window/FFT/power and block/exponential averaging | Preserve; consume its power outputs instead of reimplementing Welch |
| dsp_isp_library/dsp/spectrum/peak_search | One global maximum and threshold flag | New per-band sums/moments/counts add independent instrument capability |
| common_scaffold/image/stereo_subpixel | Complete-axis WTA and precise quadratic interpolation | Preserve; avoid another generic interpolation implementation |
| block_ca_cfar | Local noise-window threshold detections per cell | Preserve; bands integrate instrument energy/occupancy rather than CFAR windows |
| dsp_isp_library/dsp/spectrum/mag_squared | Signed16 complex bin to unsigned32 exact/shifted power | Reuse unchanged in the actual composed example |

Production RTL/README/SPEC searches for bandpower, spectral centroid, spectral
moments and channel occupancy found no matching configurable multi-band service.
The exact input/output semantics are in README; this package does not claim that
band statistics or their mathematical definitions are novel algorithms.

## Unchanged internal support source

`../dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv` is already Git tracked.
Current SHA256 is
`43ba24b43046a80b32bb1a2bc7e71c23181ab4ca7a6fbb58d7756e9cb86489da`,
and read-only `git show HEAD:<path>` yielded the same bytes. Its source header
identifies the repository DSP-05 implementation; repository original-contribution
Apache-2.0/NOTICE applies. No file-level third-party notice or external dependency
is present. Source bytes and headers are unchanged; the package references the
single canonical existing file rather than copying a duplicate module.

The older DSP-05 `ip_manifest.json` has a different historical source digest.
Those older tests/resources are not claimed to cover current bytes. Current
support-source bytes are saved with the B34 executed-input snapshot and finite
I/Q-chain test. The B33 canonical source list has no `mag_squared` declaration,
so this support source is a new cumulative source path but not new or modified
production arithmetic. `B34_DELIVERY.json` provides the exact mapping/hash.

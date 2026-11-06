# Primary reference, license and semantic deduplication

Read-only external review on2026-11-07 before authoring:

- SciPy official `scipy.spatial.distance.cityblock` documentation:
  https://docs.scipy.org/doc/scipy/reference/generated/scipy.spatial.distance.cityblock.html
  HTTP200. It defines the L1 sum of absolute coordinate differences. This
  package independently applies half that distance to two normalized discrete
  power distributions and derives an exact positive-cross-product form.
- SciPy upstream LICENSE.txt:
  https://raw.githubusercontent.com/scipy/scipy/main/LICENSE.txt
  HTTP200, BSD-3-Clause conditions inspected. No SciPy implementation, source
  routine, table, test fixture or license text is copied or translated. The new
  implementation/model/TB/docs are original Apache-2.0 repository contributions.

The web connector returned HTTP500/channel unsupported. Known primary URLs were
then read directly with bounded PowerShell Invoke-WebRequest; no upstream code
or package was executed. An author-book PDF request via the same failing web
connector yielded no content and is not relied on as evidence.

Internal production RTL/README/SOURCES searches and direct source review found:

| Existing asset | Existing semantic coverage | Independent addition here |
|---|---|---|
| dsp_isp_library/dsp/stft/stft_welch | Overlap/window/FFT/power/averaging | Adjacent normalized shape comparison after its power output |
| spectral_band_monitor | Fixed-band sums/moments/peak/count | Stateful cross-frame full-distribution distance |
| occupied_spectral_bandwidth | Equal-tail interval in one spectrum | Adjacent distributions rather than one-frame coverage |
| spectral_peak_interpolate | Three-point vertex of one selected maximum | Full-distribution redistribution, including multiple peaks |
| spectral_kurtosis | Per-bin first/second sums over finite spectra | Order-sensitive adjacency; AABB and ABAB have the same moments but different adjacent distances |
| ks_histogram_distance | Maximum difference of normalized empirical CDFs | Half-L1 of normalized bin masses; oscillating per-bin changes accumulate |
| exact_1d_transport | Balanced-mass distance-weighted optimal coupling | Unequal frame totals normalized independently; moved mass is not weighted by bin distance |
| paired_spectral_coherence / spectral_bicoherence | Complex second-/third-order phase relations | Power-only adjacent-frame shape state and lifecycle |

For masses [1,0,1,0] and [0,1,0,1], normalized KS is1/2 and this TV is1.
Moving an entire point mass to any distinct bin gives TV1, while the transport
cost depends on separation. These operators cannot be reconstructed from the
existing peak/band/KS/transport summary fields alone. This is an engineering
capability boundary, not an algorithmic novelty or patentability claim.

Unchanged canonical source reuse, without copying or modification:

```text
cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v
cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v
cores/acceleration/integer_divider/rtl/integer_divider.v
cores/signal_processing/dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv
```

Two instances of the same RAM module are physical banking, not a duplicate
canonical declaration. Main and example lists are explicit and resolved from
this package root. Sources have no package/include/ROM/vendor-IP dependency.
Plan/seal pin exact current bytes and tool/runtime closure. Root committed-blob
proof and any later execution qualification remain separate from source review.

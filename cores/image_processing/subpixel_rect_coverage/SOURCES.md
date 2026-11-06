# Provenance and semantic deduplication

Reviewed2026-11-06. New RTL, wrapper, oracle and TB are original Apache-2.0
work. No external source was copied, translated, imported or executed.
The bounded runner follows the already audited local finite-runner structure.

Primary open-source read-only reference: Google Skia at pinned commit
`e46e225442e884b537ea53ed72b11f7631399897`:

- [SkScan_Antihair.cpp](https://raw.githubusercontent.com/google/skia/e46e225442e884b537ea53ed72b11f7631399897/src/core/SkScan_Antihair.cpp),
  HTTP200,33434 bytes, SHA256
  `0ebcb5a161d9d0a1bede8d6b518e9d63803cfce25f51d46b380e4490323ffdd2`.
  Fully read. `do_scanline`, `antifilldot8`, `AntiFillXRect` and `AntiFillRect`
  illustrate fractional24.8 edge coverage and clipping that retains fractions.
- [LICENSE](https://raw.githubusercontent.com/google/skia/e46e225442e884b537ea53ed72b11f7631399897/LICENSE),
  BSD3-Clause, HTTP200,1507 bytes, SHA256
  `5f787c1dee3c56547f09ccc2906ab5f5293c4d8dd6c8654e573216c38e908dbd`.
  Fully read.

The external source motivates the area-coverage operation. This package uses
exact17-bit area and exact RNE paint scaling, with an original interface and
serial hardware schedule. It does not claim byte-alpha identity with Skia.
The web search connector returned an upstream500; pinned upstream raw HTTPS
provided the primary files. Neither upstream code nor project helpers ran.

Production semantic search and direct README/RTL review found:

| Existing capability | Difference from this increment |
| --- | --- |
| polygon_raster_mask | Dense binary pixel-center parity; no fractional area |
| triangle_rgb_raster | Pixel-center/top-left mask and RGB; no area antialiasing |
| rgba_sprite_blit | Integer source/destination clip and flips; no fractional geometry |
| rgba_bilinear_coverage | Four-texel reconstruction, explicitly no geometric/minification area |
| indexed_texture_sampler | Integer resident indexed point sampling |
| video_compositor | Color composition, no rectangle-to-fractional-area generator found |
| common_scaffold img_geo_area_resample.v | Image pixel-area resampling, not geometry coverage generation |

Unmodified actual composition dependency:
`cores/image_processing/rgba_porter_duff/rtl/rgba_porter_duff.sv`.
Root confirmed it is a mode100644 committed blob in BASE
`d32ea87e268c5957b7203560a5b46864e282a6e1`, OID
`00eecbfea8836bddfb84130df12b432d52b79fba`.
Canonical bytes are additionally pinned in the plan/seal. No existing source
or executed evidence is changed. Semantic novelty is an engineering scope
statement, not a patentability assessment.

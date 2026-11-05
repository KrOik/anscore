# Provenance and semantic deduplication

The RTL, TB, Python reference/runner and example are original ANSCORE code under
Apache-2.0, the repository license. No upstream source was copied or adapted;
there are no third-party runtime or RTL dependencies.

Before writing RTL, read-only searches inspected image/ISP/operator source
catalogs and actual nearby behavior. Existing Floyd–Steinberg
`cores/system/common_scaffold/image/error_diffusion/floyd_steinberg.sv` excluded
the initial proposed dither direction. Full repository RTL/README/SPEC content
searches for seam carving, seam removal and content-aware resize found only
`cores/system/common_scaffold/image/seam_find/README.md`, explicitly a two-image
stitching-mask service that does not remove pixels. The existing geometric
resizers, filters, seam stitching and stream compaction do not compute and remove
a minimum-energy connected path from a captured image.

Read-only external reference inspected before implementation:

- [li-plus/seam-carving carve.py](https://github.com/li-plus/seam-carving/blob/586dbe909ce69518e1602af30440a5f851a8b65f/seam_carving/carve.py)
  (pinned commit: `586dbe909ce69518e1602af30440a5f851a8b65f`).
  `_get_backward_seam` demonstrates path cost/predecessor/traceback and
  `_remove_seam_mask` demonstrates actual pixel removal. This core's clamped
  central-difference energy differs from the upstream Sobel energy; no
  bit-equivalence with that package is claimed.
- [Upstream MIT license](https://github.com/li-plus/seam-carving/blob/586dbe909ce69518e1602af30440a5f851a8b65f/LICENSE),
  copyright2020 Jiahao Li, read before authoring. The license was inspected even
  though no upstream code is included. No upstream script was executed.

The web search tool returned HTTP500. Direct HTTPS GETs to raw.githubusercontent.com
successfully read `master/seam_carving/carve.py` and `master/LICENSE`, followed by
GitHub's commits/master API resolving the SHA above. These were technical
reference inputs only. No upstream build, installer or dependency was run.

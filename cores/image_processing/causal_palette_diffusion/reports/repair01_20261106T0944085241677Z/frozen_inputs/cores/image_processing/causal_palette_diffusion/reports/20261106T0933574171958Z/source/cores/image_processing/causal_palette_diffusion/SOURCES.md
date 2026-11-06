# Provenance and semantic deduplication

Baseline98176a8f970354ebd6191d0370662ab35ff53664. No shared RTL is modified.
Read-only semantic searches covered `cores`, ISP/operator/common-scaffold
libraries, `components`, `systems` and `assets`, including visible untracked
legacy sources. Patterns included lens shading/vignetting/gain mesh,
Floyd/Atkinson/error diffusion, causal/streaming dither, palette, two-level and
halftone. Actual neighboring source was inspected:

* common_scaffold lens_shading already has four CFA meshes, exact bilinear
  interpolation, host configuration and double-bank commit; excluded.
* common_scaffold floyd_steinberg captures/stores complete input/result frames,
  supports serpentine and fixed uniform output codes; this new design has
  distinct causal line-only storage and runtime palette semantics.
* operator_library acc_img_dither_bayer4x4 uses an ordered spatial threshold;
  it does not propagate quantization error.
* grayscale_anisotropic_diffusion evolves image intensities rather than
  quantization residuals; palette texture samplers and BMP expansion implement
  lookup rather than causal quantization.
* actual `extended_library/src/isp_rgb2gray.v`, `isp_stream/gray_sobel_stream.v`
  and `dsp_isp_library/isp/csc_stream.v` were read for composability. The minimal
  actual example reuses only the first, unchanged. Its asynchronous-low reset
  and CE-qualified valid are explicitly adapted, with no CE/RV assumption.

The only RTL dependency outside this package is
`cores/system/extended_library/src/isp_rgb2gray.v`; it computes
`floor((77*R+150*G+29*B)/256)` from RGB888 in a CE-enabled registered stage.
No selftest cell, old checker, model, runner, historical binary or generated
result is a dependency. SOURCE_SEAL.json binds exact current raw bytes and the
runner archives every source at its original repository-relative path before
any child. No ROM, init file, host-computed image, firmware, external runtime
library, generated RTL or vendor block is required for hardware use. Test
vectors are independent simulation inputs, not hardware lookup results.

## Fixed external read-only inspection before development

Pillow11.3.0 tag resolved through GitHub API to commit
`89f1f4626a2aaf5f3d5ca6437f41def2998fbe09`. Read-only official raw retrieval
inspected `src/libImaging/Convert.c` and `LICENSE` before writing this package.
The initial web-tool transport returned500; direct PowerShell HTTPS retrieval
from the same official pinned raw URLs succeeded. No upstream script, build,
test, binary or import was executed, and no upstream source was copied.

Convert.c `tobilevel` and palette-conversion loops demonstrate row-local causal
error state and nearest-palette choice. Pillow uses different intensity/error
rounding and a fixed threshold in bilevel mode. This package specifies its own
signed Q4 rounding and two-level palette; no Pillow bit equivalence is claimed.
Pillow's MIT-CMU license and copyright/permission terms were inspected. Because
no upstream code is incorporated, this independently written RTL/model/TB/runner
is Apache-2.0 under the included repository license. Exact URLs, content sizes
and SHA256 appear in references.json. These references do not create a runtime
dependency or network build step.

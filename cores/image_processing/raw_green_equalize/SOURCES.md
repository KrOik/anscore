# B39 source and semantic reuse record

Baseline `1e9e9130cef71127d2c8d2762affe815b067b9f5`. New files are isolated in
`cores/image_processing/raw_green_equalize`. All shared production sources are
unchanged; no board or old-regression evidence is inherited by the new package.

Production closure:

| File | Role |
| --- | --- |
| `rtl/raw_green_equalize.sv` | New original integer cross-green gate/mix and frame owner |
| `example/green_bayer_rgb.sv` | New actual RAW8/10 equalizer to RGB composition |
| `../../signal_processing/dsp_isp_library/infra/window/stream_window.v` | Unchanged synchronous VALID line-window engine |
| `../../signal_processing/dsp_isp_library/infra/window/stream_window_padded.v` | Unchanged row capture/REPLICATE replay wrapper |
| `../../signal_processing/dsp_isp_library/isp/bayer/rtl/bayer_demosaic.sv` | Unchanged RAW8/10 floor-average demosaic, example only |

The two source lists contain the exact closure. The example has two physical
window instances and explicit canonical-to-legacy CFA remapping. No CE-qualified
stream is connected as ordinary ready/valid. Reset polarity conversion is
explicit and all dependencies use the same clock and synchronous reset events.

Semantic inspection covered all image-processing package names, canonical
common-scaffold image directories, DSP ISP modules and operator-library image
kernels. Actual arithmetic/interface source was read for RAW four-plane white
balance, RAW radius-two DPC, defect-map, basic-ISP DPC, local window engines,
the Bayer kernel, canonical Bayer frontend, temporal denoise and temporal median
background. Nearby LSC/HDR/CLAHE/MHC/deinterlace/tone-map/sprite catalogs were
checked and excluded.

| Existing function | Why the new function differs |
| --- | --- |
| RAW white balance | Already computes independent Gr/Gb global/ROI gains; new correction is spatial local and gates on diagonal range and small center/other-green difference |
| RAW DPC / defect map | Same exact CFA phase defect donors; new rule mixes opposite green phases only, and rejects large mismatches rather than treating them as defects |
| RGB median8 DPC | All-channel median outlier replacement; no Bayer-phase selection or small cross-green gate |
| Bilinear / MHC Bayer | Reconstructs RGB; new stage emits RAW with R/B untouched |
| Motion denoise / median background / three-field deinterlace | Uses prior frames/fields; new stage has no temporal history |
| Tone map / CLAHE / LSC / sprite | Exposure/CDF/mesh/rendering behavior, no local Gr/Gb phase correction |

Official RawTherapee source and license were retrieved read-only before writing
the package. The GPLv3-or-later implementation is not imported, translated or
executed. The new code has independently specified unsigned integer arithmetic,
a3x3 diagonal gate, exact rounding and a ready/valid contract. references.json
records immutable URLs and full-file hashes. No external temporary source was
saved. The full Apache-2.0 license applies to original new code only; existing
dependency provenance remains in its own unchanged package.

The first execution's exact source archive is retained with FAIL status. A
separate root-approved minimal TB cancellation-driver correction was reviewed
before its own six-child plan. Production RTL, oracle, original runner,
original PRECHECK_PLAN, all20 original vectors and all first-run raw streams
were unchanged. The repair archives14 current inputs and a byte-identical copy
of the original FAIL receipt before any child. Its simulations read the original
frozen vectors directly; no oracle was imported or prepared again. Both TB
versions remain traceable. The failed VVP remains permanently retained, with
its exact path/hash in FAILURE_ARCHIVE.json.

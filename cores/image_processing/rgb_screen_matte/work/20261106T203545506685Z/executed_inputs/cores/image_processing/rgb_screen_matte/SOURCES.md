# Semantic, source and license boundaries

Baseline: `c9117a22459e954d496dfa66dd94d6f67188c862`. This is a new B50 package;
all B49 controls, reports and production sources remain untouched.

Read-only discovery listed the full common-scaffold image and modern image
directories and searched production RTL/README/SPEC across cores, components
and systems for matte, screen key, despill, curve flattening and nearby image
capabilities. Historical reports/delivery/preparation mirrors were excluded
from semantic discovery. Actual nearby source and interface documents were
read, including acc_chroma_key, video compositor, ISP colorspace, RGBA
Porter-Duff, sprite/coverage and vector geometry interfaces.

| Existing capability | Why this is independent |
|---|---|
| operator_library acc_chroma_key | Four Cb/Cr lane classifications using box/diamond thresholds; soft is a category bit. It does not produce fractional opacity, modify RGB or create premultiplied paint. |
| video_compositor and multiframe exact-key OSD | Exact RGB equality and supplied blend weights; neither computes continuous screen matte or screen-channel excess suppression. |
| rgba_porter_duff / sprite / coverage | Combine supplied alpha or geometric/texture coverage; they do not derive screen transparency from original video RGB. |
| ISP CCM/CSC/Gamma/3-D LUT/tonemap | Color/transfer/exposure mapping; no supplied-key distance with independent matte and spill policy. |
| LSC/chromatic aberration, denoise/deinterlace | Spatial calibration/filter/history behavior, not this per-pixel keyed paint service. |

The opponent metric, exact squared-distance ramp, threshold equality/error
policy and integer quantization are original documented contracts. They are
not claims of YCbCr/OBS/FFmpeg equivalence or editorial-quality matting.

Public code was actually read through native read-only HTTP on2026-11-07
(Asia/Shanghai). The web search tool returned HTTP500; no remote code was
executed. No upstream implementation source is copied, translated, bundled
or imported by this package. External files are not offline dependencies.

* FFmpeg n8.0 `libavfilter/vf_chromakey.c`: full source and explicit
  LGPL-2.1-or-later header read. Its chroma-neighborhood distances, alpha ramp
  and YUV formats informed capability comparison; its normalized square-root
  metric and neighborhood processing are not reproduced here.
* FFmpeg n8.0 `libavfilter/vf_despill.c`: full source and explicit
  LGPL-2.1-or-later header read. Its screen-channel excess concept informed
  the review. This core uses its own max-other-channel bound and exact byte
  arithmetic, rather than translating its floating-point options.
* OBS31.1.2 chroma-key shader and repository COPYING (GPLv2 text) read. The
  shader contains neighborhood sampling, nonlinear matte and desaturation;
  these are deliberately outside this integer core's contract.
* Skia fixed commit f533d40349006b96193948901fa9d1bffafe33fb geometry source
  and BSD3-clause LICENSE read for a rejected quadratic-curve candidate.
  No Skia code or curve functionality is included in this delivery.

The actual URLs and read-only scope are recorded in references.json. All new
RTL, example, model, TB and documents are original Apache-2.0 contributions
under the copied repository LICENSE. The independent oracle uses Python
arbitrary integers and Fraction; it does not parse or import production RTL
or a sibling project's helper. Test expected values do not use the hardware
division fold or quotient-stage implementation.

## Offline HDL closure

Core files.f contains only rtl/rgb_screen_matte.sv. Example files.f adds the
original wrapper and exactly one canonical sibling support source:

`cores/image_processing/rgba_porter_duff/rtl/rgba_porter_duff.sv`

Observed raw file size3567 bytes, SHA256
`0ebf835719a73aaaa94782323e4f1e89a0721ee0c1fbc99ddd48dc4234e64877`.
This SHA also matches the canonical rtl/rgba_porter_duff.sv entry in the B49
source snapshot's rgba_porter_duff package. This observation does not replace
the root's required exact baseline/raw-blob and final input-map audit.
No copy, edit, bridge, extra sampler or frame memory is introduced. Existing
Porter-Duff qualification does not automatically qualify this composition.

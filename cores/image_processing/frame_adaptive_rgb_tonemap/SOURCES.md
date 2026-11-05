# Provenance and capability boundary

Baseline inspected: `a517a23c066c997a81573e988a9beb7fbbc42736`.
This package is original Apache-2.0 RTL, example, testbench and Python code.
No third-party source, coefficient image, generator, script or binary is
copied into the production closure. `LICENSE` is the Apache 2.0 text used by
other original ANSCORE packages. No external build or runtime dependency is
needed.

Before creating the RTL, read-only inspection retrieved OpenCV commit
`6d381e029fe26248675f48b2d44df23f4f288d11`, actual
`modules/photo/src/tonemap.cpp` and root `LICENSE`. The actual source header
retains BSD 3-clause terms, while root LICENSE is Apache 2.0. Both were read;
no upstream code was executed or translated. A subsequent read-only fetch
records pinned URLs, UTF-8 response hashes, byte lengths and access times in
`references.json`; those timestamps describe that provenance-capture fetch.

Reference source:
<https://github.com/opencv/opencv/blob/6d381e029fe26248675f48b2d44df23f4f288d11/modules/photo/src/tonemap.cpp>

Actual root license:
<https://github.com/opencv/opencv/blob/6d381e029fe26248675f48b2d44df23f4f288d11/LICENSE>

OpenCV's source contains floating point global/channel adaptation,
logarithmic statistics, exponentiation and final normalization. This package
instead defines an integer max-channel arithmetic mean exposure pedestal,
one shared RGB rational denominator and one final rounding per channel.
It makes no claim of OpenCV, Drago, Reinhard or Mantiuk compatibility.
The reviewed software is method context rather than imported implementation.

Semantic deduplication searched/read standalone image packages,
`cores/system/common_scaffold/image`, DSP/ISP and extended ISP assets,
`cores/acceleration/operator_library`, and video compositor. It compared
algorithm, state ownership, frame handling and interfaces rather than names:

| Existing asset | Existing capability and why this package adds behavior |
| --- | --- |
| `image/hdr_dol/raw_hdr_dol.v` | Calibrated dual-exposure RAW fusion already includes threshold motion rejection/deghosting. A proposed new HDR merge was rejected as duplicate. It leaves extended radiance and explicitly has no display tone map. |
| `image/raw_gamma/raw_gamma.sv` | Host-loaded single-channel 8/10/12-bit piecewise tone LUT; does not derive exposure from same-frame HDR RGB or couple channels. |
| `dsp_isp_library/isp/ccm/rtl/ccm_stream.sv` | Signed CCM and optional per-channel configured PWL,5-stage elastic stream. Actual tone interpolation/header read; no frame-derived adaptation or shared max-channel normalization. |
| `image/color_lut3d/color_lut3d.v` | Exact host-loaded 3D cube interpolation. It can encode a fixed RGB map but has no internal same-frame exposure statistic and is limited to 8..12-bit channels. |
| `image/auto_exposure/img_ae_controller.v` | Consumes external frame statistics and updates sensor exposure/gain actuators; it neither consumes/stores RGB pixels nor tone-compresses them. |
| `image/histogram` and histogram matching | Internal gray8 HE/CLAHE/CDF mapping, distinct from 16-bit linear RGB/max-norm exposure and a common RGB denominator. |
| `image/retinex/retinex_ssr.sv` | Gray local log-ratio with fixed 5脳5 binomial surround and signed output/optional gain mapping; no same-frame global HDR RGB adaptation. |
| Operator library gamma/key/color operators | Per-beat lookup, color conversion and key/blend decisions, not internal same-frame statistics/replay and HDR radiance compression. |
| Video compositor | Raster timing, routing, alpha/OSD blend and control; lacks this adaptive radiance-to-code transform. |

Nearby temporal denoise, dehaze, lens shading, chromatic aberration, bilateral,
and color-space assets were excluded: their data dependencies and transforms
are distinct. No existing production file or shared catalog is modified.

Exact offline production closure is one RTL file listed in `files.f`.
The example adds only its complete port wrapper. Validation uses the Python
standard library and local Icarus tools; original/raw and directed-continuation
receipts preserve executable copies, vectors, hashes and the retained TIMEOUT.

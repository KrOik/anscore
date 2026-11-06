# Semantic reuse and provenance

New original Apache-2.0 sources are isolated in this package. Baseline is
`a68ca46815777c15c638c42a03899c83385bf052`; shared mature sources are not edited
and old board/timing evidence does not qualify this new combination. Both window
files, median_network.v and csc_stream.v match baseline blob bytes exactly.
The untouched csc_coeffs.vh is `i/lf w/crlf attr/text=auto`; its clean Git blob
`daefd533e25eba8fb846600993fe39c2ad400b05` matches the baseline with no Git diff.
The plan freezes its actual CRLF SHA256
`08b16491f667ab5b3bb70154d292e75f9c36b2e80aea10aec4cf627d4fcc7c84`.

| Existing source | Reused behavior |
| --- | --- |
| `../../signal_processing/dsp_isp_library/infra/window/stream_window.v` | VALID3x3 register-bank window |
| `../../signal_processing/dsp_isp_library/infra/window/stream_window_padded.v` | REPLICATE row capture/replay, instantiated once per Y/Cb/Cr plane |
| `../../signal_processing/dsp_isp_library/isp/median/median_network.v` | Two unchanged unsigned K3 ten-stage bitonic median networks |
| `../../signal_processing/dsp_isp_library/isp/csc_stream.v` | Actual example's forward/inverse four-stage BT.601 full-range conversion |
| `../../signal_processing/dsp_isp_library/isp/csc_coeffs.vh` | Existing checked-in Q16 conversion constants |

The new core contributes per-frame ownership, atomically connected three-plane
windows, Y-range gate, original-center alignment, chroma-only selection and
completion/counters. The RGB example contributes actual configuration and final
RGB retirement ownership. Existing B39 finite-driver and evidence-runner patterns
were adapted locally; no old test or oracle was executed and no old qualification
is inherited.

Semantic dedup inspected independent image-processing packages, common-scaffold
image/signal_video/pipelines, old DSP ISP modules and operator image kernels:

| Existing capability | Concrete missing behavior supplied here |
| --- | --- |
| `median_stream` / `img_filter_median3x3` | Ordinary scalar median lacks cross-plane Y gating and retained original Y/chroma bypass alignment. The median arithmetic is reused here. |
| Bilateral, guided, Wiener, NLM, anisotropic diffusion | Different weighted/local-adaptive grayscale/intensity filtering; they do not expose this same-resolution independently specified chroma-only order statistic gated by original Y range. |
| `chroma_422` / `chroma_420` and reconstruction | Sampling/anti-alias and interpolation change component rates. This service retains every Y/Cb/Cr raster position and only rejects local chroma outliers. |
| RAW AWB, B39 green equalizer, Bayer/MHC | Sensor-phase gains/local cross-green correction or demosaic operate before reconstructed color; this service accepts full YCbCr pixels after demosaic. |
| Chromatic aberration / CCM /3-D LUT / tonemap | Channel remap, color transform and exposure mapping do not provide local chroma median cleanup. |
| OSD/chroma key/sprite/deinterlace/temporal denoise | Overlay/key or temporal fields/history are unrelated; this service has no second frame or rendering memory. |

Official RawTherapee `rtengine/rawimagesource.cc` was read at fixed commit
`b2ee504c47e5e6d5e054395aa12bf1fe43bd1c3c`, including the complete false-color
correction section2982..3163. Its floating-point YIQ chroma median is followed
by neighborhood blur and potentially repeated passes. The GPLv3-or-later source
and full LICENSE were read only: no upstream source was saved, imported,
translated, executed or used as a bit-exact oracle. This new one-pass unsigned
YCbCr rule adds a precise Y-range gate and full border bypass, independently
specified before RTL. Fixed URLs/full-file SHA256 values are in references.json.
The external search tool returned HTTP500; direct read-only HTTPS retrieval
supplied the actual official files. Development/offline execution requires no
network and no external Python package.

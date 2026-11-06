# Source and novelty audit

Baseline:3a58c99bda6f6f62a34d1c20247d3b42d8d89006 (B47 final).
The source snapshot contains188 qualified package objects,411 canonical HDL
sources and413 module declarations. Package paths/top names and every canonical
file were read/searched as text; no imports, AST or historical helper was run.

The relevant prior capabilities were checked beyond names:

* common_scaffold/image/bad_pixel/raw_bad_pixel_frame.sv captures a full frame,
  sorts eight radius-two same-phase donors and applies abs(C-median8)>fixed T.
  Its README explicitly excludes an edge-directed predictor.
* common_scaffold/image/defect_map/defect_map.sv uses a calibrated map and an
  exhaustive nearest original-good same-phase donor search. It does not infer
  this adaptive detector from live local content.
* dsp_isp_library/isp/basic_isp/rtl/isp_dpc.sv uses independent channel-plane
  median8 and a fixed threshold. Existing Bayer demosaic and lens shading
  reconstruct/gain samples, rather than this defect rule.
* raw_green_equalize blends cross-green phases for small locally consistent
  imbalance, preserving R/B. This core instead repairs large same-phase
  outliers and never blends Gr/Gb.
* common temporal denoise/blend, temporal median background, deinterlacing,
  RAW optical-black rows, texture sampling, geometric coverage and Porter-Duff
  composition do not implement the published adaptive local predictor.
* operator_library's byte-lane median3, Bayer dual lane and blend arithmetic
  were inspected for reuse. They do not match 8/10/12-bit same-phase envelope
  detection; adding protocol conversion would not replace the required logic.

New original files:RTL core,actual composition,independent preparation oracle,
TB,finite runner and documentation, Apache-2.0. No third-party implementation
was copied. Primary vendor documentation is method context only; references.json
records access/hash and the limited relationship. No bit-equivalence is claimed.

Direct unchanged production dependencies (captured in the source seal):

* dsp_isp_library/infra/window/stream_window.v
* dsp_isp_library/infra/window/stream_window_padded.v
* dsp_isp_library/isp/bayer/rtl/bayer_demosaic.sv (actual example)

No bridge files or changes to mature dependencies are introduced. New runner
run_child lifecycle text is reused verbatim from the reviewed B47 C runner
after LF normalization; its complete new main and plan require fresh root/peer
review. Initial simulation records persist execution_image_sha256 and
execution_image_prechecked=true before subprocess.Popen. Process limits remain
20 seconds,5 seconds tree termination,and one shared2-second exit/capture
observation. A failed child ends the attempt with evidence retained and no retry.

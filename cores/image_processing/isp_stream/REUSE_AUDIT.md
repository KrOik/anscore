# IP-03 source reuse audit, 2026-10-21

This records inspected source capabilities, not release or board qualification.
No old evidence is promoted to full-size sustained 25K acceptance here.

| Canonical source | Inspected behavior | Integration decision |
|---|---|---|
| common_ip_scaffold/image/raw_black_level/raw_black_level.sv | Full-frame RAM capture then serialized replay; manual four-plane or same-frame optical-black means; rejects WIDTH/HEIGHT >256 | Preserve existing asset; requires a streaming manual-offset path for 320/640 widths; same-frame automatic mean is a separate buffering policy |
| common_ip_scaffold/image/pipelines/img_bayer_window_frontend_draft.v | Configured RAW8/10/12 frontend, synchronous window, Bayer interpolation, explicit response/errors; crops one pixel per border | Candidate, must test continuous full-size operation and measure actual II; preserve crop dimensions and phase |
| common_ip_scaffold/image/window/img_window3x3_valid_draft.v | Dependency instantiated by Bayer frontend | Inspect and verify its RAM/timing and complete-frame behavior before selection |
| common_ip_scaffold/image/isp/img_isp_bayer_interpolate.v | External-window bilinear kernel; legacy no-window mode explicitly unsupported | Reuse with actual window frontend, do not expose unsupported mode as implemented |
| common_ip_scaffold/image/isp/img_isp_awb_gain.v | Three-stage elastic RGB888 Q8.8 gain, rounded/saturated, SOF commit | Candidate for reuse unchanged, test complete chain and pending config at frame boundary |
| common_ip_scaffold/image/isp/img_isp_ccm.v | Four-stage elastic signed Q6.10 matrix/bias, SOF commit | Candidate for reuse; target DSP and Fmax must be measured |
| common_ip_scaffold/image/isp/img_isp_gamma_lut.v | Double-bank synchronous RGB LUT, complete-load guard, SOF commit/bypass | Candidate for reuse; runtime LUT loading and bank reuse must be tested |
| common_ip_scaffold/image/isp/img_isp_awb_stats.v | Elastic RGB pass-through, accepted-pixel sums/counts, explicit flush and held snapshot | Reused unchanged in rgb_frame_statistics; wrapper supplies EOF flush and original frame ID; tested narrow-sum saturation and snapshot backpressure |
| wave2_ip_20k/src/isp_demosaic.v | Existing RGGB-only 8-bit window kernel, CE-gated, no autonomous ready interface | Preserve existing reference; richer canonical frontend above is a better candidate for this stream contract |

Paths in the table are relative to projects/. Source SHA256s are recorded in
reuse_sources.json from actual current files. Local authorship alone does not
assign redistribution rights; dependency licensing remains an L5 gate.

Required chain-level decisions/tests remain OPEN: RAW payload width and Bayer
origin; output crop vs border extension; frame ID and SOF/EOL alignment under
backpressure; atomic updates of the entire multi-stage configuration (individual
modules committing at their own SOF does not alone prove chain atomicity);
bypass latency; no cross-frame contamination; pixel golden at every stage;
continuous 320x240@30 then feasible 640x480@30 chain; actual II, Fmax and physical
resources; 25K controlled source/CSR/LA acceptance. No camera is required for
the controlled virtual-RAW milestone, but simulation alone does not close it.

# B37 sources and semantic increment

Baseline `46630205095a13ab95e1b5bebea0094c2a390390`. New RTL, connection example, TB, Python mathematical reference and metadata are original ANSCORE contributions under root Apache-2.0 `LICENSE` / `NOTICE`. All new package files use `* -text` from their first write. No mature source or Git state is changed by this package's authoring.

Pre-existing active dependencies, reused unchanged at their original paths:

| Source | Role | SHA-256 |
| --- | --- | --- |
| `cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/cplx_mac.sv` | Per-sample exact power and lag complex product | `21f17250725762362f70e9d9c3f7165a6c3bc52326c45696bccafb097e37f4fd` |
| `cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v` | Shared exact serial squares and threshold product | `40e6dffb4b0c87a5ee71e414ced900cd2ebf6019013a043261c7a2a47a9de60f` |
| `cores/acceleration/stream_atan2/rtl/stream_atan2.sv` | Actual signed29 P to modular binary-turn phase connection | `525dd5d06816b7120492dc50fd117f34e14027bf3ec2c811cb8dba77748d230a` |

All three are original ANSCORE contributions covered by Apache-2.0/NOTICE. The `stream_atan2` source pre-existed in the workspace but was untracked at the B37 baseline and absent from the B36 canonical export list. B37 first includes this exact source in the export/commit closure, with scoped `-text` attributes; it does not import the rest of the legacy package. Its original bytes and the hash above are retained. The current phase connection has only the finite evidence explicitly reported here and does not inherit old qualification. No external RTL, vendor primitive, ROM download or generator is required. Active compilation resolves the original paths; executed-input archives preserve evidence copies without adding duplicate active module definitions. Historical helper qualification is not inherited by this new combination.

The original finite attempt, `reports/20261106T042700_831623Z/results.json` (SHA-256 `03e3b91407c419fe819d97dbed608f4d18091092c83e2d92f6e87610fd8b79be`), remains **9 PASS + 1 FAIL**. Three core simulations passed. The actual phase simulation stopped at the concurrent scene's first-result watchdog: its original 400-clock budget started before any input, omitting the 279-clock warmup from that wait. No production RTL, example, helper, original runner, original plan or original vector is changed by the repair. [REPAIR01_PLAN.json](REPAIR01_PLAN.json) records the four-hunk TB-only change, both TB hashes and the independent two-child repair plan. All original archived sources, four vector sets, twenty raw logs and four VVP images, including the failed image, are retained unchanged. The repair may copy only the already archived phase vectors, with no new numerical preparation.

The separately reviewed and authorized repair completed exactly two PASS children, `repair01_compile_example` and `repair01_sim_example`. Its receipt `repairs/repair01/reports/20261106T044044_962242Z/results.json` has SHA-256 `76bdd41c4c50d13a30f465a85f0149db45bfaea1bbb8a33e25a46edd46926950`. It archives all 13 actual inputs and an exact copy of the original phase vector bytes; zero preparation calls occurred. Post-run independent hashes confirm all original evidence unchanged and all new current/archive pairs, raw logs, vectors, tools and VVP images intact. This supplies the current connection's finite qualification while retaining the original 9 PASS + 1 FAIL history.

`cplx_mac` has synchronous active-low reset and actual lane packing `{b_im,b_re,a_im,a_re}` as implemented by its slices. Its first header summary packing line is inconsistent with those slices; this new core follows the implementation and independently tests the cross direction. Its input is widened before conjugation. The serial multiplier has asynchronous active-low reset and CE-qualified transfers; a registered reset bridge and constant CE=1 adapt it explicitly. `stream_atan2` has synchronous active-high reset and ordinary ready/valid, one task slot, ITER+2 service and modular binary-turn phase. The phase wrapper retains matching metadata and shares the external reset.

Read-only pre-implementation upstream reference: GNU Radio **v3.10.12.0**, annotated tag object `522b220f24cbf0df9789a2d8eff57ee3d3f58f52`, commit **`ec7a3239645162ffea1925e6f1e6e62bf1349d03`**:

- [`gr-digital/lib/ofdm_sync_sc_cfb_impl.cc`](https://github.com/gnuradio/gnuradio/blob/v3.10.12.0/gr-digital/lib/ofdm_sync_sc_cfb_impl.cc): delayed-conjugate product, moving sums, energy normalization, phase and plateau block connections.
- [`gr-digital/include/gnuradio/digital/ofdm_sync_sc_cfb.h`](https://github.com/gnuradio/gnuradio/blob/v3.10.12.0/gr-digital/include/gnuradio/digital/ofdm_sync_sc_cfb.h): public metric and the documented energy estimate from both half-symbols.
- [`COPYING`](https://github.com/gnuradio/gnuradio/blob/v3.10.12.0/COPYING): GPL version3 text; the source headers specify **GPL-3.0-or-later**.

The sources were inspected as read-only text through HTTPS after the web service returned HTTP500. They were not saved, imported, translated or executed. Only public mathematical relations and boundary interpretation informed this original integer design. This package does not reproduce GNU Radio's plateau-center trigger, alternating-carrier policy, stream scheduler or floating point implementation, and makes no claim to be a drop-in GNU Radio/OFDM synchronizer.

The B36 static snapshot lists 144 functional packages. Review also covered actual relevant library interfaces:

- `dsp_isp_library/dsp/lms/rtl/lms_stream.sv` already implements adaptive LMS and NLMS, including serial and delayed-update variants. A renamed canceller would duplicate that capability.
- `dsp_isp_library/dsp/correlation/rtl/correlation_stream.sv` performs sliding correlation against a configured known template, with lag/argmax, real/complex direction and tail policies.
- `acceleration/stream_autocorrelation` performs exact finite-block real autocorrelation over multiple lags.
- `dsp_isp_library/dsp/recovery` provides BPSK Costas/Gardner closed tracking loops, rather than unknown-content burst repetition acquisition.
- `acquisition/micarray_doa/src/micarray_doa_core.v` captures multichannel blocks and scans microphone-pair lags for a direction estimate.
- `common_scaffold/peripherals/pulse_measurement` and `event_interval_recorder` already measure physical pulse/event timing; they are not analog/repetition-pattern detectors.
- `paired_spectral_coherence` operates on paired spectral bins accumulated across independent segments. It has no time-domain sliding delay/window, repetition run or sample position event.

The new increment is fixed-lag, overlapping-window, two-half energy-normalized complex repetition detection and sustained-run acquisition in accepted-sample time, with an actual P-to-phase service. It preserves coarse acquisition limitations and does not rename an existing generic correlation or tracking core.

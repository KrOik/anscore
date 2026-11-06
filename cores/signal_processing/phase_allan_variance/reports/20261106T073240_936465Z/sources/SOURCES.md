# Source provenance and semantic closure

Baseline: `31a83135a22f845d85840524986895217567625c` (B40 closeout).
All new RTL, integer oracle and TB are independently authored, Apache-2.0.
The mathematical definition is public; no upstream code is incorporated,
translated, imported or executed.

Read-only external reference: official AllanTools repository, commit
`f80988a9181ea7b66aac03697f183f898d97ee24`, file
[`allantools/allantools.py`](https://github.com/aewallin/allantools/blob/f80988a9181ea7b66aac03697f183f898d97ee24/allantools/allantools.py),
functions `oadev` and `calc_adev_phase`. The source explicitly uses the overlapping
second-difference sum and cites NIST SP1065 equation11, page16. Its official
[`LICENSE.txt`](https://github.com/aewallin/allantools/blob/f80988a9181ea7b66aac03697f183f898d97ee24/LICENSE.txt)
was inspected: GNU LGPL version3. It is reference-only; its NumPy implementation,
deviation sqrt, uncertainty estimate and tau-list selection are not reused.
No upstream dependency or copied source is needed offline. The independent
oracle uses whole-record Python integers, direct list indexing, sum and divmod.

Read-only semantic review covered actual production/legacy RTL, not just names:

| Existing implementation | Actual behavior and independent new capability |
| --- | --- |
| `dsp_isp_library/dsp/statistics/rtl/statistics_stream.sv` | Power, RMS, amplitude/peak and threshold statistics; no m-spaced phase second-difference estimator. |
| Legacy `stream_autocorrelation/rtl/stream_autocorrelation.v` | Aperiodic lagged product sums; no cropped three-sample difference energy, Allan normalization or validity contract. |
| `dsp_isp_library/dsp/correlation/rtl/correlation_stream.sv` | Template correlation/convolution MAC and argmax; no phase-stability estimator. |
| `dsp_isp_library/dsp/hilbert/rtl/phase_freq.sv` | Analytic phase and adjacent modular phase difference; no multi-interval stability statistic. |
| `operator_library/rtl/acc_quadrature_jitter.v` | Encoder transition checks and interval EWMA/threshold; no Allan variance. |
| `event_interval_recorder/rtl/event_interval_recorder.sv` | Physical reference-to-observation intervals and loss FIFO; no uniform phase-record reduction. |
| `common_scaffold/peripherals/frequency_counter/frequency_counter.sv` | Fixed clock-gate edge counts; no overlapping phase estimator. |
| `pulse_fraction_timing/rtl/pulse_fraction_timing.sv` | Pulse-lobe threshold crossings and width; no phase stability statistic. |

Canonical closure, common_scaffold, operator_library, DSP/transforms legacy
trees and actual cores/components/systems RTL were searched for Allan,
frequency-stability and second-difference estimator semantics. No existing
implementation supplies this bounded function. Legacy `stream_phase_unwrap`
was read but is absent from the baseline Git tree and is not a dependency.

Production closure (explicitly listed in files.f/example/files.f):

| Source | Role | Baseline raw SHA256 |
| --- | --- | --- |
| `rtl/phase_allan_variance.sv` | New record estimator | Frozen seal |
| `example/trigger_phase_allan256.sv` | New actual trigger capture composition | Frozen seal |
| `../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv` | Unchanged `fp_div_iter` RNE normalization | `280d4aa40ca513befb76ef3dae03cf32e88b773c5cefcf526b8c9cfb89e1d3cb` |
| `../../system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v` | Unchanged serial18x18 multiplier | `40e6dffb4b0c87a5ee71e414ced900cd2ebf6019013a043261c7a2a47a9de60f` |
| `../../system/stream_bus_library/rtl/sys_trigger_window.v` | Unchanged trigger+255 capture | `5fd8f05c4f6b63ed0a0a39bbc51a51b73907559a5de90f611a3dfaaae553bd37` |

No includes, coefficient files, ROMs, external source generators or runtime
downloads are required. Original helper evidence is preserved; the new
composition does not inherit hardware qualification. The package starts with
`* -text` to preserve exact support and evidence bytes in Git.

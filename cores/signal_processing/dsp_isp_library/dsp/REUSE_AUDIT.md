# DSP reuse audit — 2026-09-25

Scope: goal.md DSP 1–16. Status is inventory/model preparation, not acceptance.
Inspected root AGENTS, goal, IP_CORE_SOP, optimization ledger/latest board SESSION,
dsp_20k and sigproc_20k manifests/validation logs, wave2 manifest, FIR/CIC RTL,
DDS and FFT interfaces. No nested AGENTS found by recursive file search.
The new goal's synchronous reset/Stream contract supersedes the older SOP's
asynchronous reset/clk_en convention for new cores; existing cores are preserved.

| ID | Requirement | Actual reusable implementation | Missing/new integration and dependencies |
|---|---|---|---|
| DSP01 | integer/rational resampling | dsp_20k/src/fir16.v; sigproc_20k/src/cic_dec8.v | FIR is unsigned 8-bit positive symmetric 16 taps; not general signed polyphase. New coefficient generator, phase scheduler, L/M counts and tail contract; Stream buffering |
| DSP02 | DF-II-T SOS | no matching core identified in these inventories | New signed MAC, stable-coefficient checks, atomic update and feedback-state policy |
| DSP03 | DDC/DUC | dsp_20k/src/dds_nco.v, cordic.v; CIC/FIR above | Complex mixer, quadrature phase alignment, interpolation path, signed FIR and rate/gain tests |
| DSP04 | magnitude/power/RMS/peak | cordic.v provides vectoring arithmetic | Window/block accumulators, square root, peak index/ties, threshold/scale and saturation |
| DSP05 | spectrum pre/post | sigproc_20k/src/fft64.v | Hann/Hamming/Blackman ROM generation, complex power, averaging and calibrated peak search |
| DSP06 | correlation/matched | FIR arithmetic ideas only | Complex signed programmable templates/conjugation, direction and tail; wave2 match_sad is image SAD selftest, not correlation |
| DSP07 | AGC | magnitude/CORDIC arithmetic candidates | Energy detector, linear/log control, attack/release, silence and limiter; shared log/exp |
| DSP08 | carrier/timing recovery | DDS and dsp_20k/src/pid_core.v arithmetic only | Neither constitutes recovery loop. Reference modulation/sample rate and detectors, capture/lock validation still required |
| DSP09 | DC/baseline | no dedicated core identified | New models/spec in dc/; Stream/config foundation before RTL |
| DSP10 | halfband/CIC compensation | FIR/CIC above | Signed odd-tap halfband, decimate/interpolate scheduler, compensation coefficient tool and spectral tests |
| DSP11 | Farrow | no matching core identified | Cubic polynomial branch MAC, atomic fractional delay and continuity tests; no ASRC claim |
| DSP12 | Hilbert/envelope | CORDIC vectoring arithmetic | Signed antisymmetric FIR, real-path delay, phase unwrap/zero policy |
| DSP13 | Goertzel | no matching core identified | Block recurrence, coefficient/window tool, state growth and terminal power pipeline |
| DSP14 | STFT/Welch | FFT64 | Overlap buffers, window, bandwidth-limited frame scheduler, PSD normalization and accumulation |
| DSP15 | LMS/NLMS | no matching core identified | Signed programmable taps, wide coefficient state, energy floor/divider, update/readback and convergence tests |
| DSP16 | PFB | FFT64; FIR arithmetic ideas | Small-channel signed polyphase bank, schedule/FFT frame buffering, gain/isolation checks |

## Evidence boundaries

- `dsp_20k/ip/MANIFEST.md` references historical physical digests for DDS/FIR/PID;
  this is reuse evidence, not fresh Stream qualification. FIR RTL advances history
  on in_valid but calculates the previous history: adapt and test alignment explicitly.
- CORDIC `doc/VALIDATION_LOG.md` reports 4,096 independent vectors and 11 raw-output
  physical frames, latency 17 and II=1. It uses clk_en/async reset without ready.
  The existing optimized arithmetic can be reused behind a correctly stalled wrapper,
  but reset and Stream tests are additional work.
- FFT README is newer/more specific than sigproc manifest: current memory is
  synchronous register arrays, not BRAM; 768 enabled compute cycles plus load/read.
  173 physical frames/11,072 bins are reported. Stage-wise wrapping is intentional
  legacy behavior; arbitrary full-scale complex data can overflow. New chains must
  either prove bounded input scaling or introduce a separately qualified variant.
- CIC is fixed N=3,R=8,M=1 with 17-bit Hogenauer modular integrators/comb. This
  intentional modulo realization is mathematically different from accidental output
  overflow; preserve it and separately specify gain normalization/saturation.
- wave2 manifest explicitly says wrappers wrap `st_<unit>` selftest cells. Asset
  counts or digest PASS cannot establish an externally usable streaming IP.
- latest physical SESSION establishes only repaired SSUM UART transport. It does
  not extend evidence to any new DSP IP; no board action taken in this task.

## Integration ordering

Stream/config + rounding → DC/statistics/SOS/signed FIR → resampling/halfband/
Farrow/Hilbert/Goertzel → FFT framing/spectrum/STFT/PFB; DDS+rate chains → DDC/DUC;
energy+division/log → AGC/NLMS; detectors+loop reference → recovery loops.
Resource estimates cannot substitute isolated/wrapper/chain synthesis and 27 MHz
P&R. Keep ≤15K LUT-class, ≤4 Gowin DSP cells per delivered board image.

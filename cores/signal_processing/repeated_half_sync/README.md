# Repeated-half time-domain synchronization

B37 baseline: `46630205095a13ab95e1b5bebea0094c2a390390`.

`repeated_half_sync` scans a finite complex sample stream for adjacent length-L segments related by a common complex rotation. It calculates an exact normalized repetition metric for every complete 2L-sample window and produces one event after H consecutive qualified windows. It uses no uploaded template and adds a coarse burst-acquisition service beyond block autocorrelation, template correlation, spectral coherence and the existing BPSK tracking loops.

Current state: **LINT_PASS / UNIT_SIM_PASS (three finite core profiles and the actual phase connection) / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. The first approved [PRECHECK_PLAN.json](PRECHECK_PLAN.json) attempt completed **9 PASS + 1 FAIL**: both syntax checks, all four compilations and the first three core simulations passed; the actual phase simulation stopped at a TB watchdog in its final concurrent scene. The separately approved [REPAIR01_PLAN.json](REPAIR01_PLAN.json) then passed its two explicit compile/simulation checks after the limited TB fix. Across both receipts: **12 children, 11 PASS, 1 historical FAIL, 4 successful simulations**. No synthesis, placement/routing, STA, board or large regression has run.

## Exact metric and event

For the accepted sample with zero-based index n, after n>=2L-1:

```text
P[n] = sum(i=n-L+1..n) Conj(r[i-L])*r[i]
E[n] = sum(i=n-2L+1..n) |r[i]|²
M[n] = 4*|P[n]|²/E[n]²                         when E>0
qual = E>0 && E>=min_energy && M>=threshold_q16/65536
```

Both halves contribute to the energy normalization. Cauchy and `4*Ex*Ey <= (Ex+Ey)²` give `0<=M<=1`. The implementation tests the exact integer inequality

```text
(Re(P)² + Im(P)²) << 18 >= threshold_q16 * E²
```

because `4*65536=2^18`. There is no division, rounded metric, intermediate truncation or saturation on legal data. Equality qualifies. Threshold Q16 values 1..65536 are legal; 65536 represents unity. The raw energy has input-code-squared units, as do both signed cross components. A fixed common input scale cancels in M; the energy floor remains scale dependent. Unequal amplitudes between the halves reduce this normalization even when the halves are otherwise correlated.

`m_end=n`, and `m_start=n-(2L-1)` is the complete window's first sample. A failed window, a zero-energy window or a window below the floor clears the consecutive run. On the Hth qualified window, `m_event=1` once and `m_event_start` holds the first window start in that run. Further qualified windows produce no new event until a failure rearms the run. `m_event_start=0` whenever `m_event=0`. Each command starts with fresh run and sample history.

These are **accepted-sample indices**. Input pauses stretch physical time without advancing the sample sequence. Upstream hardware must preserve sample order and spacing in the underlying sampled signal; pausing a non-buffered ADC loses that interpretation. The module has ordinary backpressure and does not guarantee an arbitrary physical sample rate.

The event is a coarse repetition/plateau qualification, not an exact OFDM symbol boundary or a verified packet identity. A CW tone or other periodic signal can qualify. The first threshold crossing and the H-window confirmation depend on noise, amplitude, channel and waveform. There is no calibrated false-alarm rate, optimal timing pick, cyclic-prefix estimator, multipath boundary selection, FFT, equalizer or timing/CFO correction.

## Parameters and exact widths

| Parameter | Default | Supported |
| --- | --- | --- |
| DATA_W | 16 | 8..16 signed bits per real/imaginary lane |
| L | 16 | 1..64, including nonpowers of two |
| MAX_SAMPLES | 1024 | 2L..4096 |
| TAG_W | 8 | 1..32 |

Let D=DATA_W, A=ceil(log2(L)), with A=0 at L=1. `CROSS_W=2D+1+A` is the output width of both signed P components and unsigned E. Each sample power is at most `2^(2D-1)`, and each product component has the same absolute bound. Thus `|Re(P)|,|Im(P)| <= L*2^(2D-1)` and `E <= 2L*2^(2D-1)` fit, including both signed-minimum input lanes. Inputs are extended to D+1 signed bits before imaginary negation. The running add-new/subtract-old expressions have two further bits, so their intermediate values are also represented at L=1.

Squares retain `2*CROSS_W` bits; adding them retains one more. One serial multiply datapath has A_W=`2*CROSS_W+2`, B_W=`CROSS_W`, output width `3*CROSS_W+2`. It serves the three squares and threshold-times-E² sequentially. At the minimum supported CROSS_W=17, its output width exactly covers the shifted numerator; all larger supported widths have more room. No variable-width or combinational division is used.

## Interface and ownership

All transfers are on rising `clk` edges with ordinary `valid && ready`. There is no external CE. `rst` is synchronous active high and cancels the command and pending output. Readiness/validity are gated low while reset is high. After release, wait for `c_ready`; the helper bridge supplies a complete reset edge before reopening commands. The multiplier's asynchronous active-low reset changes only at rising edges, and its CE is tied high. No interface is a clock-domain crossing.

`c_valid/c_ready` accepts `c_samples[31:0]`, `c_threshold_q16[31:0]`, `c_hold[31:0]`, `c_min_energy[63:0]`, and opaque `c_tag`. Full widths are validated before narrowing, in that order. N must be 2L..MAX_SAMPLES; T 1..65536; H 1..64; the floor must fit unsigned CROSS_W. A floor larger than every reachable energy is allowed if it fits the width and simply prevents qualification. H may exceed the number of available windows, producing no event.

One batch owns the core through its final result retirement. It accepts N samples on `s_valid/s_ready`. `s_iq[DATA_W-1:0]` is signed real; `[2*DATA_W-1:DATA_W]` is signed imaginary. `s_last` must be asserted only on sample N-1. Keep all fields stable until their handshake. Config changes after acceptance do not affect the batch. No input timeout is implemented.

There are N-2L+1 ordinary records, one for every full window, with no warmup records. The record contains status, end/start indices, event start, qualification/event bits, raw E/Re(P)/Im(P), captured tag and last. `m_last` normally identifies the window ending at N-1. The complete record remains stable until accepted. Input is blocked while the core's output is pending; no command falls through on the final result-retirement edge.

| Status | Meaning | Result |
| --- | --- | --- |
| 0 | OK | Exact raw statistics; `m_qual` may be zero or one. |
| 1 | BAD_LENGTH | One fatal zero-statistics marker, index/start 0. |
| 2 | BAD_THRESHOLD | One fatal zero-statistics marker, index/start 0. |
| 3 | BAD_HOLD | One fatal zero-statistics marker, index/start 0. |
| 4 | BAD_FLOOR | One fatal zero-statistics marker, index/start 0. |
| 5 | BAD_LAST | Fatal zero-statistics marker at the expected input end index. |
| 6 | ARITH | Fatal zero-statistics marker at the current input end index. |
| 7 | ZERO_ENERGY | Preserve the zero statistics, qualify/event=0, continue. |

Fatal markers assert last, zero all raw statistics and event fields, and cancel all remaining input/results. For an input index before warmup, fatal start is 0; later it is the current window start. Previously retired records remain valid if a later input LAST is malformed. Length rejection takes precedence over threshold, then hold, then floor. Legal data cannot raise arithmetic invariants or MAC flags; the three passing core profiles each exercised both explicit TB fault injections and recovery. ARITH resets every helper before its marker becomes visible, preventing in-flight MAC results leaking into recovery. External reset may cancel any held marker or ordinary result.

## Architecture and cycle budget

Three separately scheduled synchronous memories retain L raw complex samples, 2L powers, and L complex products. The first 2L samples mask every old slot until it has been written in the current batch. No memory payload reset loop is needed. Each ring has one scheduled read and write in different states, with explicit pointer wrap at L or 2L, including nonpower L. The default payload is `(10D+2)*L=2,592` bits (324 bytes); supported maxima use 10,368 bits (1,296 bytes).

One unchanged `cplx_mac` performs `Conj(current)*current` and `Conj(delayed)*current`. It contains four signed(D+1) multiplier operators. For sample acceptance edge 0, RAM reads occur at 1, the two MAC issues at 2/3, output consumption at 5/6, guarded accumulation at 7 and ring write at 8. Warmup samples can therefore be accepted every 9 clocks. A complete zero-energy/below-floor window becomes valid at edge 8.

Let C=CROSS_W and `Lm=C+ceil((3C+2)/8)+1`. A nonzero window passing the floor becomes valid at `13+4*Lm` clocks after its sample acceptance, and can transfer one clock later. With an always-ready consumer, the next sample can transfer after `15+4*Lm` clocks. Defaults C37/Lm53 give first validity 225, first transfer 226 and full-window sample II 227. Supported maxima C39/Lm55 give 233, 234 and 235. Input gaps and output stalls add waiting; no unconditional deadline exists under unbounded stalls. These are static RTL cycle schedules; finite first-valid and warmup-II checks passed for D8/L1, D16/L3 and D16/L64. The default-width syntax check did not simulate the default L16 profile. These checks do not imply a measured clock frequency.

Architecture risk: **MEDIUM**, due to four narrow inferred multiplier operators, a shared wide carry-save/fold datapath and memory inference. No LUT/FF/BRAM/DSP, Fmax, power or physical throughput measurement is available.

## Actual phase connection

`example/sync12_phase.sv` fixes D12/L16/MAX_SAMPLES1024/tag8 and connects exact signed29 P components to the existing `stream_atan2(IN_W=29,PHASE_W=24,ITER=24)`. Every window, including non-events and error/zero markers, passes through the angle service with status, indices, event fields, last and tag retained in one metadata slot. Angle zero flags exactly P=(0,0). Metadata holds throughout angle backpressure. The core may hold one subsequent result while the earlier angle waits; a new command is blocked until the final angle retires.

For `r[k+L]=r[k]*exp(j*omega*L)` with matching underlying content, P has **positive** phase `omega*L`. The output is a modular binary turn, with 0=positive real, quarter turn=positive imaginary and half turn=negative real. Interpreted as signed24, the frequency branch is

```text
frequency_offset / sample_rate = signed(m_phase) / (2^24 * L)
```

It is inherently ambiguous modulo `1/L` cycles/sample, so the unambiguous principal branch is `[-1/(2L), +1/(2L))`. A signal near or beyond that range aliases; the module does not detect the alias. This phase is the reused CORDIC's finite-precision approximation, not a correctly rounded ideal atan2 guarantee. The new finite plan checks its relation to the new detector against mathematical axes and independent atan2 values, with at most two circular phase LSB tolerance on nonaxes. The example contains no FFT, oscillator, resampler, derotation, signal-level synchronizer or physical-time estimator.

## Reproducibility and finite-check history

The first approved run followed [PRECHECK_PLAN.json](PRECHECK_PLAN.json): four bounded profiles, two syntax checks and four compile/simulation pairs, 10 total HDL children, each at most 20 seconds, stopping on the first failure. Maximum L64 uses N<=145; full N4096 playback and maximum Cartesian workloads are excluded. The actual phase example includes concurrent input and a 260-clock held result so a subsequent detector result must wait without corrupting earlier phase metadata.

The original runner archived all 11 actual executable inputs before four numerical preparation calls and archived all four vector sets before the first HDL child. Its immutable [first receipt](reports/20261106T042700_831623Z/results.json), SHA-256 `03e3b91407c419fe819d97dbed608f4d18091092c83e2d92f6e87610fd8b79be`, records 9 PASS + 1 FAIL and three successful simulations. Original source archives, vectors, twenty raw log streams and all four VVP images are retained. There is no automatic retry or cleanup. The reference directly slices whole windows, sums integer expressions and tests the exact inequality; it does not reproduce ring updates or helper algorithms. Phase values use mathematical atan2 and exact axes, with two circular LSB tolerance only for nonaxes. The three passing core profiles cover reset during history, MAC, wide multiply, decision and held output, each followed by recovery.

The failed `sim3` scene began its first `expect_result` before the first sample, but used the ordinary 400-clock post-sample watchdog. D12/L16 needs `9*(2L-1)=279` warmup clocks plus `13+4*Lm+26=207` detector/angle clocks. The limited TB repair grants only that first concurrent wait `279+207+8=494` clocks and immediately restores 400 for subsequent results. It changes no numerical, precision, per-result latency or input deadline check. Production RTL, example and helpers remain byte identical. The separate repair runner archived 13 inputs, copied `vectors3.txt` exactly (SHA-256 `7433eacb5baf4433b69b4458e4495370b9243e0696871d532c5999169c388b9a`), and ran only `repair01_compile_example` and `repair01_sim_example`, with no preparation or rerun of the first three profiles. Both passed. The [repair receipt](repairs/repair01/reports/20261106T044044_962242Z/results.json) SHA-256 is `76bdd41c4c50d13a30f465a85f0149db45bfaea1bbb8a33e25a46edd46926950`; the longest wait was 487 clocks. The original failure receipt and failed VVP remain unchanged.

| Successful simulation | Records | Accepted samples | Resets | Held output clocks | Phase checks | Exact latency checks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| First `sim0`: D8/L1/M64/T1 | 138 | 159 | 6 | 552 | 0 | 121 |
| First `sim1`: D16/L3/M127/T8 | 208 | 346 | 6 | 832 | 0 | 191 |
| First `sim2`: D16/L64/M4096/T32 | 75 | 3497 | 6 | 300 | 0 | 58 |
| Repair `repair01_sim_example`: D12/L16/M1024/T8 | 153 | 1108 | 7 | 868 | 153 | 132 |

These four successful simulations contain 574 records, 5110 accepted samples including canceled setups, 179 commands including canceled setups, 25 resets, 8 injected faults and recoveries, 2552 held-output clocks and 502 exact latency checks. The phase simulation additionally checks in-flight angle reset and simultaneous input with the held phase result. Counts exclude the incomplete failed simulation. [QUALIFICATION.json](QUALIFICATION.json) and [B37_DELIVERY.json](B37_DELIVERY.json) preserve both receipt identities, the TB before/after mapping and the successful-check accounting.

The active offline HDL closure is in package-root-relative `files.f` and `example/files.f`. The three pre-existing helpers are used at their original paths without modification; the phase source is first included in the export/commit closure by B37. See [SOURCES.md](SOURCES.md) for provenance, licenses and the semantic-reuse comparison.

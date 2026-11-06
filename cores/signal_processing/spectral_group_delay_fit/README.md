# Spectral group delay and phase-linearity fit

`spectral_group_delay_fit` estimates a bandwise delay from the unwrapped
binary-turn phase of consecutive, naturally ordered FFT bins. It also exposes
the exact sufficient statistics for phase spread and linear-fit residual.
The real example accepts signed I/Q vectors through unchanged `stream_atan2`;
the core itself reuses unchanged `stream_phase_unwrap`, the histogram serial
multiplier and `integer_divider`. No FFT or stored sample RAM is added.

Baseline `50b8d36a3ce65cae5c4b3ab4604fa24f3567204b`; original Apache-2.0 code.
Current status SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED. This specification and
paper cycle budget are not execution or physical implementation evidence.

## Exact contract

Parameters: PHASE_W8..24, MAX_BINS2..256, TAG_W1..32,
MAX_FFT_LOG2 4..16; defaults16/64/8/16. Width parameters are derived and must
not be overridden. A command owns the module until its one result retires.
Runtime `c_count,c_first_bin,c_fft_log2` are full32bit fields. Validation uses
the full fields and a33bit first+count sum: 2<=count<=MAX_BINS,
4<=fft_log2<=MAX_FFT_LOG2, first_bin+count<=2^fft_log2. Indices do not wrap.

Each phase is unsigned modulo2^PHASE_W per turn. The first phase is interpreted
as signed PHASE_W. Subsequent steps use the nearest signed modular difference;
an exact half-turn tie chooses the negative half-turn, for both modular input
directions. The caller must ensure the actual adjacent phase step is identifiable
by that rule. Aliased steps cannot be diagnosed here. Absolute first_bin changes
metadata, while the centered slope depends only on offsets k=0..N-1.

For the integer unwrapped phases phi[k], define:

```
D = N*sum(k*k) - sum(k)^2
B = N*sum(k*phi) - sum(k)*sum(phi)       signed
C = N*sum(phi*phi) - sum(phi)^2
E = C*D - B*B
delay_q16 = RNE(-B * 2^(fft_log2+16) / (D * 2^PHASE_W))
```

`m_b,m_c,m_d,m_residual_numerator` are exact B/C/D/E. Delay is signed samples
times65536, so decreasing phase gives positive delay. SSE of the phase fit is
E/(N*D) in phase-code squared, and mean squared residual is E/(N*N*D).
N2 always has E0. Constant phase is legal, with C/B/E/delay0 and positive D.
The bandwise OLS slope is a finite-band estimate; for nonlinear phase it is
not a pointwise group-delay derivative. No RMS, R-squared, confidence interval,
frequency interpolation, transfer-function division, magnitude qualification or
coherence calculation is included. The caller defines FFT and response semantics.

`s_last` must be high exactly at the declared last sample. `s_invalid` rejects
an unusable phase, such as a zero I/Q vector, before unwrap or statistics update.
One sample is in flight. Status0=OK,1=BAD_CONFIG,2=BAD_LAST,3=INVALID_PHASE,
4=ARITH (helper/invariant fault). Invalid phase has priority over bad LAST.
Errors return zero mathematical fields; command metadata/tag and the number of
actually accepted samples remain. A rejected sample counts in `m_received`.
The core stops accepting samples after the first error and resets all reused
helpers through a fence before publishing its error result.

One clock, synchronous active-high public reset, ordinary ready/valid, no CE or
CDC. Ready/valid/busy are low under reset. Sources hold every offered field
while blocked. Held results remain stable without a stall limit. Reset cancels
partial commands, helper computation and held results without a response.
No new command is accepted on the edge retiring the prior result. Error fence
adapts the old multiplier's active-low asynchronous reset and fixes its CE high.

## Real I/Q composition

`example/iq_group_delay_fit.sv` instantiates actual `stream_atan2` and this core.
IN_W2..32, ITER4..30; other legal domains match the core. Defaults16/24.
At most one I/Q vector is pending: source readiness requires fit phase-ready,
atan ready and no pending vector. A zero result becomes invalid phase. The
angle result's LAST is transferred atomically. A future angle cannot hide behind
an early error. Shared reset cancels atan, unwrap, arithmetic and ownership.
There is no second unwrap and no copied CORDIC oracle. Compile the source lists
relative to this package directory.

## Area and service budget

Two full-precision multiplies per phase (phi squared, k*phi), then eight final
products are time-shared through one unsigned magnitude multiplier. Signed
products use a separate sign. A single unsigned restoring divider performs only
the final delay division; RNE uses the full remainder and then restores sign.
k squared advances by2*k+1, so it needs no extra multiplication. There is no
sample history RAM. The arithmetic and state deliberately trade transaction
latency for bounded storage and operator reuse; they do not target dense FFT
throughput. See ARCHITECTURE for widths, cancellation and alternative review.

Let M=max(B_W,C_W,D_W)+1, H=M+ceil(2*M/8), V=B_W+MAX_FFT_LOG2+16.
With always-present legal input and always-ready sink, a phase's earliest next
acceptance is2*H+6 edges later. First result is10*H+V+23 edges after the final
phase acceptance. From the earliest command acceptance the full N result needs
(2*N+8)*H+6*N+V+18 edges. I/Q adds ITER+2 per sample, hence its command-to-valid
budget is (2*N+8)*H+N*ITER+8*N+V+18. Retirement adds one edge, and the next command
can be accepted one further edge later. Gaps and stalls add cycles.

Defaults M59/H74/V75: final-phase-to-valid838, N64 command-to-valid10541;
I/Q ITER24 final-vector-to-valid864, N64 command-to-valid12205. Configuration
and core phase errors expose valid one edge after the bad acceptance; adapter
phase errors expose it ITER+3 after the bad vector. No timing rate, Fmax, DSP
inference, physical area, power, PnR or board performance has been measured.

## Frozen finite checks

The finite plan has five isolated archived oracle preparations before any HDL,
two syntax children and five compile/simulation pairs: core P8/N5/T1,
P16/N64/T8, P24/N256/T32, actual I/Q P8/N5/T1/ITER8 and P16/N64/T8/ITER24.
Each core profile scores39 cases/156 held cycles; each I/Q profile25/100.
Cases include constant and nonlinear phase, signed initial phase, positive and
negative delays, multiple wraps, exact half-turn ties, N2 residual, first-bin
invariance, max unfolding (P24/N256), final RNE ties with both signs/parities,
full32bit configuration errors, last early/missing, invalid and recovery.
I/Q uses exact axes/diagonals, including a zero vector; it makes no accuracy
claim for general CORDIC angles.

Core has seven live cancellation fixtures: partial input, each sample multiply,
early/late final multiply, divider and held output. I/Q adds live atan. Each
has a separately scored fresh recovery, with4 held cycles. Two additional
results hold a real future command across busy and held output, check no
retirement fallthrough, and observe its later actual handshake. Every offered
sample waits through real backpressure. Tail latency is checked exactly.
No existing regression/helper, combined repository HDL, synthesis, STA, SDF,
board, PPA or automatic retry is included.

Execution requires exact root+peer review of source, plan and seal and the one
named gate. Each preparation/HDL child has20s, taskkill tree helper5s and the
sole shared2s target-exit/reader observation. PID, exit and raw streams are
persisted before parsing. A lock or report directory blocks another attempt;
executed input and raw bytes remain frozen. `run_checks.py` never imports the
oracle or another project runner and executes only the archived finite plan.

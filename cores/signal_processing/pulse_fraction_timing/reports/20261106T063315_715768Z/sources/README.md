# Relative-height sampled-pulse timing

B40 baseline: `a68ca46815777c15c638c42a03899c83385bf052`.

`pulse_fraction_timing` measures the lobe around the earliest global peak of a finite sampled waveform. It returns the peak, its sample index, the nearest left/right intersections with an exact fraction of that peak, and their width. It composes the unchanged repository serial multiplier and RNE divider. `trigger_pulse256` actually connects the existing pre/post-trigger ring capture to the measurement core.

Status before the first approved check: **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. No model preparation or HDL checks have run. No synthesis, PnR, STA or board work is authorized.

For accepted samples x[k], caller baseline B and captured polarity s=+1 or-1, define y[k]=s*(x[k]-B). Define P=max(0,max(y)), p=the earliest index attaining positive P (p=0 if P=0), and the exact threshold H=P*F/256 for commanded F1..255. Subtraction widens before polarity negation. Baseline is a fixed caller value; no baseline fit, clipping or adaptive estimator changes the waveform.

For P>=min_peak, search outward from p to the first sample on each side with y<=H. All intervening samples exceed H. On the left this gives j<p and tL=j+(H-y[j])/(y[j+1]-y[j]). On the right it gives j>p and tR=j-1+(y[j-1]-H)/(y[j-1]-y[j]). Missing sides stay invalid. This defines the connected above-threshold lobe containing the earliest peak, including ringing and multiple peaks; no independent pulse separation is inferred. A flat maximum selects its earliest index. A plateau exactly at H uses its endpoint nearest the selected peak. An exact intersection has its exact integer position.

`left_q16=RNE(65536*tL)` and `right_q16=RNE(65536*tR)` use nearest-even rounding. Each valid position differs from this piecewise-linear waveform definition by at most 0.5/65536 sample. `width_q16=right_q16-left_q16` only when both sides exist; its error versus the exact interpolated width is at most1/65536 sample. F128 gives half-height width relative to the supplied baseline. Q16 precision is a numerical representation; sampling, noise, pulse shape and baseline error determine physical timing accuracy. No sub-sample physical accuracy or absolute timestamp is qualified.

Parameters: DATA_W8..16 (default12), MAX_SAMPLES3..4096 (default256), TAG_W1..32 (default8). INDEX_W=ceil(log2(MAX_SAMPLES)), TIME_W=INDEX_W+16 are derived port dimensions and cannot be overridden. Each sample and baseline is signed DATA_W integer ADC code. min_peak is unsigned DATA_W and must be nonzero; normalized peak can reach2^DATA_W-1. c_samples/c_fraction are full unsigned32 values, checked before narrowing. Legal N3..MAX_SAMPLES and F1..255 are captured atomically with baseline, polarity, minimum and tag.

One synchronous clock, synchronous active-high reset, no CE or CDC. Ordinary valid/ready handshakes transfer at rising edges. One command owns the core until its response retires; no command fallthrough on that edge. Only accepted samples advance indices. Exactly the Nth sample must assert LAST. Producers hold all valid payload fields until accepted. Outputs hold every field under backpressure. Gaps/stalls add unbounded wall time. Reset gates ready/valid low and cancels all partial work and held results. RAM is not reset: the accepted prefix is fully written before reads. Wait for c_ready after reset release; the asynchronous-low serial multiplier reset is driven by a clocked bridge. Divider reset is synchronous and flushes a helper fault before the error marker becomes visible.

| Status | Meaning and output |
| --- | --- |
| 0 OK | Both sides valid; peak/index, two positions and width retained. |
| 1 BAD_LENGTH | N outside supported range, precedence over all other configuration errors; zero payload. |
| 2 BAD_FRACTION | F0 or F>255; zero payload. |
| 3 BAD_MINIMUM | min_peak0; zero payload. |
| 4 BAD_LAST | Accepted LAST differs from its commanded position; abort immediately, zero payload. |
| 5 NO_PULSE | P<min_peak, preserve peak/index, no valid positions/width. |
| 6 CENSORED | One or both sides absent in this record; preserve peak/index and valid side positions, width0. |
| 7 ARITH | Impossible helper flags/quotient or illegal control state; flush helpers, zero payload. |

`m_sides[0]` validates left, bit1 right. An invalid side position is zero, including an otherwise valid record. An absent side means the finite record does not bracket that crossing; it does not prove an infinite-duration pulse. min_peak is an amplitude gate, without a detection probability or noise rejection guarantee.

One unreset synchronous-read DATA_W-bit sample RAM holds MAX_SAMPLES entries. Input collection has II1 and updates the widened peak comparator. The serial unsigned multiplier computes P*F once, with DATA_W/8 input widths. One shared `fp_div_iter` computes the two positive crossing fractions, AW=BW=DATA_W+10, FB16/OUT_W18. No per-sample multiply, wide combinational divide, full parallel peak network or external memory is required.

The normalized y range is [-(2^D-1),+(2^D-1)] signed D+1. Exact P*F needs D+8 unsigned bits. Scaled samples256*y need D+9 signed bits. Every crossing numerator and denominator is nonnegative and at most512*(2^D-1), fitting signed D+10 with its leading zero. A bracketing pair has strictly positive denominator and quotient in[0,65536]; helper flags or a larger result are invariant failures. The denominator sign cannot be lost at signed minima. Per-side integer-plus-fraction addition includes a fraction65536 carry, with final time bounded by(N-1)*65536.

Each scan probe uses a synchronous RAM read then comparison, two clocks; total probes<=N-1. Multiplier earliest input-to-output transfer is8+ceil((D+8)/8)+1 clocks (12 at default/max). Divider earliest transfer latency is D+27 clocks (39 at default,43 at max). The conservative always-ready scheduling budget is **2N+112 clocks from last sample to first result validity**, and **3N+116 clocks between successive command acceptances** with contiguous samples and immediately retired responses. The default bound is884 clocks/record; maximum is12,404. These are precheck RTL cycle budgets, pending finite checking. Physical clock frequency and sustained physical ADC rate are unmeasured; arbitrary gaps/stalls invalidate finite wall-time guarantees.

Core RAM payload is3,072 bits/384B default and65,536 bits/8KiB at D16/N4096. Scalar state includes one small multiplier's carry-save/fold registers, divider quotient/remainder, two crossing operand pairs, indices, captured config and output registers. Architecture risk **MEDIUM**: BRAM inference/packing, parameterized carry paths and helper control need later implementation review. No measured LUT/FF/BRAM/DSP, timing or power count is claimed.

The actual example fixes D12/Ncap256/tag8 and instantiates unchanged `sys_trigger_window` with PRE64/POST191/WIDTH12. `a_valid/a_ready` captures fraction, baseline, polarity, minimum and tag, then arms one acquisition. Invalid fraction/minimum returns its core error without arming capture. A trigger accompanies an accepted sample; early triggers retain available prehistory, so record lengths are192..256. Extra prehistory rolls through the existing ring. Capture drains in order into the core, with a stable length and LAST. Example combined sample RAM is6,144 bits/768B. A clocked bridge drives capture's asynchronous-low reset. No new arm is accepted until final measurement retirement. Acquisition pauses during replay/measurement and no trigger means indefinite wait; the upstream converter needs suitable buffering/ownership. The example has no physical free-running ADC or lossless continuous-capture claim.

The explicit plan has four numerical preparations, two syntax checks and four compile/simulation pairs. Each HDL child has a20s deadline; any failure stops the attempt. PRECHECK_SEAL.json binds the15 other exact inputs; all16 inputs are archived before importing/preparing the model, and all vectors precede the first HDL child. A preexisting report entry prevents automatic rerun. Root must review the complete source/model/TB/plan before the initial execution. See SOURCES.md for semantic comparison, fixed external reference and helper provenance.

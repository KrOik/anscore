# DSP-16 pfb_stream — polyphase filter bank channelizer (small M)

Critically sampled M-channel analysis filter bank: sample commutator ->
M polyphase FIR branches -> M-point FFT -> per-channel gain -> tagged
output burst. Static parameters `M in {4,8,16}`, `P in 1..16` (taps per
branch), `M*P <= 256`. Default shipped LUT `rtl/pfb_coeffs.vh` is M=8,P=8;
regenerate with `python models/model.py --emit-vh PATH --m M --p P`.

## Polyphase decomposition

Prototype lowpass `h[n]`, `n = 0..M*P-1` (Blackman-windowed sinc,
cutoff 1/(2M) cycles/sample, sum h = 1).  Input beat `n` of frame `f`
is `x[f*M + r]`, `r = 0..M-1`; beat `r` is steered to branch `r`
(natural-order commutator).  Branch `m` computes

    v_f[m] = sum_{p=0}^{P-1} h[p*M + m] * x[(f-p)*M + m]

i.e. each branch sees the sample stream at the channel rate with the
decimated prototype sub-filter `h[p*M+m]` (`p=0` = newest).  The channel
outputs are the forward M-point DFT over the branch index:

    X_f[k] = sum_{r=0}^{M-1} v_f[r] * exp(-j*2*pi*r*k/M) ,  k = 0..M-1

For an input tone `x[n] = A*e^{j*w*n}` the polyphase identity gives
`X_f[k] ~= A * H(e^{j*(w - 2*pi*k/M)}) * e^{j*w*f*M}`, so **channel k is
centred at w = 2*pi*k/M radians per input sample** (k/M cycles/sample).
Bins `k > M/2` are negative frequencies; a real tone at bin `k` appears in
bins `k` and `M-k`.  Critically sampled: output rate per channel =
fs_in/M; channel-rate carrier rotation `e^{j*w*f*M}` is *not* removed
(no derotation stage).

## Fixed-point contract

- Input `s_tdata = {im[31:16], re[15:0]}`, signed16 Q1.15 each.  For a
  real input drive `im = 0`.
- Coefficients: signed18 Q1.17 (`PFB_COEF` packed vector, index `p*M+m`
  in bits `[18*(p*M+m) +: 18]`).
- FIR product 18x16 -> 34 bits; 40-bit accumulator (max |acc| < 2^36 for
  P<=16, no wrap possible); branch output `v = sat16((acc + 2^16) >>> 17)`
  (round half-up toward +inf, then saturate).
- FFT: in-place radix-2 DIT, branch outputs written at `bitrev(m)` so
  the transform comes out in natural bin order.  Twiddles are the 8-entry
  W_16 table `(cos, +sin)` Q1.15 saturated to +/-32767 — identical
  arithmetic to `sigproc_20k/src/fft64.v`: three-product complex multiply
  in low-32-bit shift-add logic (0 DSP), `t = (g0+g1+0x4000) >>> 15`,
  butterfly `(a +/- t) >>> 1` truncated to signed16 (deterministic wrap;
  unreachable for |v| <= ~0.7 FS).  Because every stage divides by 2 the
  emitted value is `DFT(v)/M` — an in-channel tone of amplitude A appears
  as `~A/M` in its bin (headroom-by-construction).  Use cfg_gain up to
  +6 dB or accept the 1/M scale.
- Per-channel gain `g[k]` signed18 Q2.16 (65536 = 1.0, range approx
  [-2, +2)); `out = sat16((g*x + 2^15) >>> 16)`.
- `clip_sticky` latches any FIR or gain saturation; clear only by reset.

## Stream and configuration contract

Single `clk`, synchronous active-low `rst_n`.  `s_` accepts at most one
complex beat/cycle and only while `st == CAP`; `s_tready` falls during the
per-frame compute window — this is honest backpressure, not an error.
`m_` emits one burst of M beats per captured frame: `m_tid` = bin index
0..M-1 in order, `m_tlast` on the last beat, `m_tuser` = frame sequence
number mod 256 (all beats of a burst share it; that is the frame-alignment
tag the TB checks).  Data/tid/user/last hold stable while
`m_tvalid && !m_tready`.

`cfg_valid && cfg_ready` commits `gain[cfg_addr]` atomically at a frame
boundary with an idle drain (`st==CAP && rpos==0 && !draining`), so a
committed gain applies to whole bursts only — no mixed-gain frame.
`cfg_addr >= M` raises `cfg_error` and changes nothing.  In-flight frames
finish with the old gain map.

Reset clears control state, counters, the output slot, gains (-> 1.0) and
`ndepth`; history/work/snapshot RAMs are intentionally not cleared —
`ndepth` (valid frames of history, saturates at P) masks stale samples,
which makes the startup transient equal to causal zero-padding.

## Timing / throughput

Per frame of M accepted samples the serialized engine costs

    T_frame = M (capture) + (3*M*P + 2*M) (FIR: read, multiply, accumulate per
              tap plus round and clip per branch)
              + 4*(M/2)*log2(M) (butterflies: read, multiply, collapse, write)
              + 1 (snapshot)  cycles,

plus any wait while a previous output burst is still draining
(m_tready-gated).  The drain takes 2 beats per channel -- one forms and
registers the Q2.16 gain product, the next rounds, clips and presents it --
because in this flow the multiplier cells are placed with their clock pins tied
low, so their real delay never shows up in the timing report and must not share
a cycle with the 35-bit rounding add.  Those 2*M beats overlap the *next*
frame's capture.  Sustained input rate = M / T_frame samples/cycle.  Measured
in sim: M=8/P=8 -> 265.7 cycles/frame (~0.030 samp/cyc, ~0.8 MS/s at 27 MHz);
M=4/P=8 -> 125 cyc; M=16/P=4 -> 369 cyc.  No II=1 claim: this is a
burst-compute engine.

The legs used to be M*P and (M/2)*log2(M) cycles (one MAC, one butterfly per
cycle).  They were split because the board measurement of this core
(board/eth_rate_harness CORE 6) returned every word of every burst wrong,
differently on each repeat of the same request, with cycle counters matching
the model exactly: the control leg finished each frame on time, the data did
not settle inside one 50 MHz cycle.  The two worst cones were the tap cycle
(64:1 history mux -> 18x16 product -> 40-bit ripple accumulate -> 41-bit
rounding add -> four 41-bit compares -> saturation mux) and the butterfly
cycle (three 17x17 shift-add multipliers, each a five-level tree of 32-bit
ripple adds, into two more ripple adds and two 18-bit adds).  Each step is now
registered, and the twiddle multiplier compresses with carry-save instead of a
ripple tree; the arithmetic and every emitted value are unchanged, which
`tests/test_pfb.py` re-proves cycle by cycle against `models/model.py`.  The
cost is 3.1x the cycles per frame at M=8/P=8.

## Resources (synth_gowin, mapped, no P&R)

| config  | LUT1-4 | FF   | DSP(MULT18x18) | BRAM |
|---------|--------|------|-----|------|
|  M4 P8  |  4698  | 1569 |  4  |  0   |
|  M8 P4  |  5072  | 1897 |  4  |  0   |
|  M8 P8  |  6664  | 2921 |  4  |  0   |
| M16 P4  |  7709  | 3577 |  4  |  0   |
| M16 P8  | 12206  | 5625 |  4  |  0   |

The 4 DSPs are the two FIR product lanes + two drain gain multipliers;
the FFT twiddle multiply is shift-add LUT logic (no DSP).  Branch history
and FFT arrays are register arrays (FF counts above); no BRAM inferred.
All configs fit the 15K-LUT / 4-DSP budget.  M=16/P=8 is the largest legal
configuration; M*P>256 is rejected.

## Limitations

- Small M only (4/8/16).  A wide channelizer needs a different
  (streaming/BRAM) architecture.
- Serialized compute: sustained input is ~M/T_frame samples/cycle; the
  input stalls during FIR+FFT.  Sizing assumes the upstream source honours
  `s_tready` or bursty traffic.
- Output scale is `DFT(v)/M` — intrinsic headroom, but per-channel gain
  can only add ~2x; wider equalization must be external.
- No channel derotation: for non-bin-centre tones the per-frame phase
  rotates by `e^{j*w*M}` between bursts (documented, matches the model).
- Simulation + mapped-synthesis evidence only; no P&R timing or board
  acceptance claim.

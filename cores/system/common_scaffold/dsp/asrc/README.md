# Dual-clock fractional linear ASRC

`asrc_linear.sv` is an executable, synthesizable asynchronous sample-rate
converter path: independent input/output clocks, Gray-pointer async FIFO,
fractional time accumulator and signed linear interpolation. Existing
`rtl/cip_dsp_resampler.v` is a rational single-clock resampler and does not
provide this CDC path. No existing ASRC was found in the repository path search.

Input/output are signed two's-complement samples, BITS=2..24. `s_valid &&
s_ready` is an input-clock handshake; `m_valid && m_ready` is an output-clock
handshake. Hold valid and payload while stalled. No CE or frame markers.
Output is demand-driven and backpressurable, **not one output every clock**.
The downstream audio scheduler determines when output samples are consumed.

Output-clock-domain configuration uses `cfg_valid && cfg_ready`. `cfg_step`
is unsigned Q3.FRAC input samples per output, strictly positive and less than
8; FRAC=2..20. Default is unity. Zero is rejected with cfg_error and retains
the active step; accepted valid values pulse cfg_done. Updates preserve phase,
buffered samples and pending output. cfg_ready is low while an output is valid,
so a commit cannot change the step used by that output's handshake. The newly
committed step advances time **after the next output sample is accepted**;
the next sample position was already determined by the previous step. This is
sample-time continuity, not a phase restart.

The integer position is advanced by consuming intervening FIFO samples; the
fraction f interpolates a+(b-a)*f. One final arithmetic rounding uses nearest,
ties toward positive infinity. Because interpolation is convex, there is no
wrapping or saturation in valid operation, including opposite full-scale signed
endpoints. Two source samples are required even when f=0. There is no end-of-
stream extension; a finite stream stops waiting for its required lookahead.

`underflow` is output-domain sticky: an internal sample request found the FIFO
empty. Startup can set it before the first samples cross the synchronizers.
An underrun pauses without discarding phase or producing fabricated samples.
`overflow` is input-domain sticky: valid was asserted while the FIFO was full;
it is a backpressure/full-attempt diagnostic, **not evidence of dropped accepted
data**. A compliant producer retains that sample until accepted. Both status
signals must be separately synchronized if consumed in the opposite domain.

## CDC and reset contract

The FIFO has 2**FIFO_ADDR entries (FIFO_ADDR>=2), binary local pointers,
registered Gray pointers and two marked synchronizer stages in each direction.
Full detection inverts the top two synchronized read-pointer Gray bits; empty
compares local read Gray with synchronized write Gray. Conservative flag
release incurs synchronizer latency. Read data is registered in the read domain.
Small default synthesis maps storage to FFs; no BRAM mapping is claimed.

`arst_n` is **one common asynchronous assert/reset/flush input for both domains**.
Each domain releases through its own two-flop synchronizer. Assertion discards
all queued samples, interpolation state, pending output, config and diagnostics;
the default unity ratio is restored. No unilateral-domain reset is supported.
Keep reset asserted for both domains, then allow both clocks to run to complete
release; do not treat pre-release interfaces as available. There is no separate
flush command: assert the common reset to flush. Memories need no reset because
pointers invalidate all content. A reset can safely abort a pending output.

Physical integration must declare in_clk/out_clk asynchronous and preserve the
two-stage synchronizers. Apply vendor-specific max-delay/bus-skew constraints
from each source Gray-pointer register to the first destination synchronizer,
bounded by the faster source-clock period, preventing multiple Gray transitions
from arriving together. Exempt only the asynchronous crossing paths; do not
blanket-disable synchronizer-to-local timing. Verify these constraints after
place-and-route. RTL simulation is not metastability or CDC signoff.

## Quality, latency and evidence

Linear interpolation is a first-order reconstruction filter. This revision
does **not** include an antialias lowpass for downsampling, bandlimited polyphase
filtering, automatic clock-ratio estimation or a FIFO-level servo. The host must
provide a suitable step and enough input buffering. Arbitrary uncorrected clock
drift will eventually exhaust finite FIFO headroom. This is a functional linear
ASRC path, not a high-fidelity audio-rate estimator/filter implementation.

Each FIFO fetch requires request/wait states; output generation/handshake has
additional states. Minimum no-advance output pitch is 3 output clocks, with
3 more clocks per consumed source sample; initial loading and empty stalls add
latency. The default FIFO stores 16*16=256 sample bits, plus pointers and
interpolator state. Performance is bounded by FSM throughput and ratio.

Run from repository root:

```
python -B cores/system/common_scaffold/dsp/asrc/test_asrc.py
python -B cores/system/common_scaffold/dsp/asrc/synth.py
```

Independent integer and floating time-coordinate oracles check 240 outputs
across four 8/16/24-bit tests, including full-scale signed endpoints, asynchronous
3/5 and 7/2 half-period clocks, random valid gaps and ready stalls, live 0.5→1.75
ratio changes, rejected zero config, full/empty diagnostics and common reset
with nonempty FIFO. Temporary binaries are automatically removed.
Default isolated Gowin synthesis (`-noalu -nodsp`) reports 1045 LUT1-4,
58 MUX2_LUT5, 405 FF and zero DSP; CHECK reports zero problems. No board,
P&R, timing, formal CDC or audio spectral-quality result is claimed.

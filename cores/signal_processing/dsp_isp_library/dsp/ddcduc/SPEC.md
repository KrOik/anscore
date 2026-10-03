# DSP-03: DDC / DUC complex frequency-conversion chains

Two stream cores sharing an NCO and a serialized symmetric FIR:

    ddc_stream:  s(I,Q) -> complex mix *e^{-jphi} -> CIC decim R -> scale -> FIR -> m(I,Q)
    duc_stream:  s(I,Q) -> FIR -> CIC interp R -> scale -> complex mix *e^{+jphi} -> m(I,Q)

Both use signed16 Q1.15 I/Q pairs (`s_i_tdata`/`s_q_tdata` under one
`tvalid`/`tready`), single `clk`, synchronous active-low `rst_n`.  Reset or a
legal config commit clears all datapath state and discards in-flight data.

## Stage-by-stage math

### NCO (rtl/ddcduc_nco.sv)
32-bit phase accumulator; beat k uses phase `init + k*inc (mod 2^32)`
(beat k = k-th accepted input for ddc, k-th emitted output for duc).
sin/cos from a 128-entry quarter-wave case ROM `T[o]=round(32767*sin(pi*o/256))`
with quadrant mirror/negate — 9-bit effective phase resolution, *no*
interpolation.  Frequency resolution `fs/2^32`; `inc = round(fc/fs * 2^32)`;
negative frequencies via `inc > 2^31`.  Worst LUT deviation from an ideal
sine is 0.0123 FS => worst spurious ≈ **-38.2 dBc** (phase truncation, no
interpolation).  For tighter SFDR chain in an interpolating NCO or larger
table — this is a documented limitation.

### Complex mixer (3 multipliers, zero extra DSP for NCO)
    DDC  x*e^{-jphi}:  i' = xi*c + xq*s , q' = xq*c - xi*s
    DUC  x*e^{+jphi}:  i' = xi*c - xq*s , q' = xq*c + xi*s
implemented with 3 products: `m1=(xi+xq)*s` and `xi*(c-s)`, `xq*(c+s)` (DDC)
resp. `xi*(c+s)`, `xq*(c-s)` (DUC).  Products are 17x16 / 16x17 signed into
33-bit, summed to 34-bit, then round-nearest-even >>15 and signed16
saturate — the only quantization point of the stage.  |out| can reach
sqrt(2)*FS for worst-phase full-scale input; clip is counted in `sat_count`.

### CIC (Hogenauer modulo arithmetic, 40-bit)
Order N = `CIC_STAGES` (static 1..4, default 3), rate R runtime 2..64, M=1.
Decimator: N integrators at input rate (updated only on accepted beats),
comb cascade evaluated once per R beats on the post-update accumulator.
Interpolator: comb cascade once per FIR output (low rate), then R zero-stuffed
beats into N integrators at output rate.

* **Bit growth**: decimator gain = `R^N`; worst case R=64, N=4 -> 16+24 = 40
  bits exactly, so the 40-bit wrap arithmetic is provably lossless for every
  legal configuration.  Interpolator inherent DC gain is `R^(N-1)` (measured:
  1000 -> 64000 at R=8 N=3) — *not* R^N; normalize accordingly.
* Integrator/comb stages intentionally wrap mod 2^40; this is the correct
  Hogenauer behaviour, not an overflow defect.

### Scale
`out16 = sat16(RNE(v40 >> shift))`, `shift` runtime 0..24.  Normalize a
decimator with `shift = round(N*log2(R))` and an interpolator with
`shift = round((N-1)*log2(R))`; other values give deliberate residual gain.

### Compensation FIR (rtl/ddcduc_iq_fir.sv, shared)
Symmetric odd taps T = 3..31 (`taps=1` = identity bypass), unique coeffs
signed18 Q3.15 packed low-first into `cfg_coeffs[287:0]`, same convention as
`dsp/halfband/rtl/cic_comp_fir.sv`.  One shared multiplier iterates the U
folded-pair products per channel (I then Q): one pair costs 2*U+3 clocks.
The FIR is 1:1 causal, emits exactly one output per accepted input pair, and
has **no tail flush** — the last T-1 convolution terms are not emitted.
In the DDC it runs after decimation (droop compensation inside the *output*
Nyquist zone — it cannot undo aliasing).  In the DUC it runs at the low rate
before the CIC — it cannot remove images at k*fs_in; the CIC sinc^N rolloff
provides the only image attenuation (measured -69.7 dB worst image for
R=8/N=3/taps=15 comp at f_b=1/16; see summary.json).

## Gain budget (reference config R=8, N=3, taps=15 comp fp=0.2)

    DDC: mix ~1 (unit-modulus LO) -> CIC 512 -> >>9 -> comp FIR ~1.0
         net ≈ 1.0 for in-band tones; verified: 12000 -> mean (11999, 0)
    DUC: FIR ~1.0 -> CIC 64 -> >>6 -> mix ~1
         net ≈ 1.0; verified: amp 8000 -> 8159 measured (+2% comp ripple)
    Loopback (shared cfg shift=9 on both): net 1/8, verified +-8.3%.

Headroom: keep complex input amplitude <= ~0.7 FS to leave room for the
mixer's sqrt(2) worst-case sum; saturation is legal and counted, not silent.

## Rate / II contract (honest)

    ddc: output_count = floor(input_count / R)   exactly, order preserved
    duc: output_count = input_count * R          exactly
    Input accept II = 1 (mixer path is pipelined 2-deep at full rate).
    Output stalls hold all m_* fields (verified by TB monitor); input stalls
    pause the whole chain (CIC time-dilates, states hold).
    FIR serialization bound: sustained decimated-pair interval >= 2*U+3
    clocks; for R < 2*U+3 the DDC input stream backpressures through the
    skid FIFO (depth 8, level-gated accept at level <= FIFO_DEPTH-4 which
    covers the 2-cycle mix pipeline in flight — overflow flag exists but is
    never expected to fire, and did not in any test).
    DUC sustained input interval = max(R, 2*U+3); outputs II=1 inside bursts.
    There is no flush/tail contract and no frame boundary — these are
    continuous rate-conversion pipes; end-of-stream simply stops emitting.

## Configuration contract

`cfg_valid`/`cfg_ready` (ready = rst_n, always ready out of reset):
`phase_inc[31:0]`, `phase_init[31:0]`, `rate[6:0]`, `shift[5:0]`,
`taps[5:0]`, `coeffs[287:0]` commit atomically.  Legal: rate 2..64,
shift 0..24, taps 1 or odd 3..31.  Any commit pulses `cfg_done`; illegal
fields additionally pulse `cfg_error` and leave state/config untouched.
A legal commit clears all datapath state (mixer pipe, CIC, FIFO, FIR
history, counters) and loads the NCO phase from `phase_init`.  Input
acceptance is gated while `cfg_valid` is high so no transfer shares a commit
edge.  `s_tvalid` must not wait on `s_tready` (source contract); outputs are
held under `m_tready` stalls.

Defaults after reset: inc=2^32/8 (fs/8), init=0, rate=8, shift=9, taps=1.

Counters (saturating): `input_count[15:0]`, `output_count[31:0]`,
`sat_count[15:0]` (mixer+scale+FIR clip events), plus `fifo_overflow` sticky
flag on ddc_stream.

## Reused-core provenance

| Source | What was reused | Adaptation |
|---|---|---|
| `cores/signal_processing/dsp/src/dds_nco.v` | 32-bit phase accumulator + sine LUT architecture | rewritten: sync rst_n (was async), no clk_en, quadrature sin/cos via case ROM, Stream-era cfg |
| `cores/signal_processing/transforms/src/cic_dec8.v` | Hogenauer wrap integrator/comb ordering | generalized to N<=4, R runtime 2..64, dual channel, 40b |
| `cores/signal_processing/transforms/src/tw_rom_*.v` | case-table ROM technique (inferred RAM unreliable on GW2A-18C) | same technique for the NCO sine table |
| `dsp/halfband/rtl/cic_comp_fir.sv` | folded-pair shared-MAC symmetric FIR arithmetic, Q3.15 coeffs, RNE+sat | shrunk to 1 shared multiplier serving I and Q (`ddcduc_iq_fir.sv`) |
| `infra/stream/stream_sync_fifo.v` | instantiated unchanged (DATA_WIDTH=32 packs {q,i}, RAM_DEPTH=8) | DDC skid buffer between CIC and FIR |
| `dsp/halfband/models/reference.py` | `design_ciccomp` weighted-LS recipe | ported as `design_comp` in models/model.py |

No legacy file was modified; the legacy cores' async-reset/clk_en contracts
remain untouched.

## Verification (tests/test_ddcduc.py)

Transaction-level TBs (`iverilog -g2012 -Wall`, deterministic seed
0xDDC03) log every output transfer and cfg event; a Python driver compares
the full output stream **bit-exactly** against models/model.py and checks
spectra/gain against the float model.  Cases: single-tone -> I/Q DC
(rel_err 8e-5), rotating baseband + image rejection (-43.0 dB), rate sweeps
R in {2,3,5,8,16,64} exact counts, comp-FIR active, 5+4 illegal-config
rejections leaving state intact, mid-stream reset + legal reconfig,
saturation accounting, DUC tone with images at k*fs_in offsets (-69.7 dB
worst), DUC->DDC loopback bit-exact + identity within 8.3% of the
documented 1/8 shared-config gain, input mutation detected + comparator
self-check, 5 illegal static parameter rejections.  Held-valid/$fatal
monitor and reset-valid checks run every cycle.

Latest evidence: `evidence/rtl_<ts>/summary.json`, `evidence/synth_<ts>/`.

## Isolated synthesis (yosys synth_gowin, no -family flag, -noalu)

| config | LUT1-4 | FF | DSP(MULT18X18) | BSRAM |
|---|---:|---:|---:|---:|
| ddc_stream (N=3)      | 5110 | 2265 | 4 | 1 (fifo SDPX9B) |
| duc_stream (N=3)      | 4798 | 2095 | 4 | 0 |
| ddc_stream (N=4)      | 5427 | 2425 | 4 | 1 |
| duc_stream (N=4)      | 5146 | 2255 | 4 | 0 |
| chain_top loopback    | 9722 | 3995 | 8 | 1 |

Each core alone meets <=15K LUT / <=4 DSP.  The DUC->DDC loopback wrapper
needs 8 DSP — it is a test artifact, not a delivery config; a shared-engine
time-mux or a 2-cycle serialized mixer variant would be needed to host both
directions in one <=4-DSP image.

## Limitations

- NCO spur floor ≈ -38 dBc (9-bit phase, no interpolation, no dither).
- DDC anti-alias protection is only the CIC sinc^N rolloff; the post-CIC
  FIR shapes within the output Nyquist band.  For strong alias rejection
  chain `dsp/halfband` decimators or the polyphase resampler.
- DUC residual images at `f_lo +/- k*fs_in` attenuated by CIC rolloff only.
- Serialized FIR limits sustained low-rate throughput to one pair per
  2*U+3 clocks; large T with small R throttles the DDC input side.
- No tail/flush: trailing FIR terms are never emitted; streaming count
  contract only.
- Simulation + isolated synthesis evidence only; no P&R, 27 MHz timing or
  board acceptance yet.

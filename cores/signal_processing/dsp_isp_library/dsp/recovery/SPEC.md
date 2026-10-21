# DSP-08 recovery: carrier_loop + timing_loop

Second-order digital PLLs for carrier and symbol-timing recovery on the
reference configuration below.  Both are *real closed loops* — phase/timing
error detector -> PI loop filter -> NCO/phase accumulator feedback — not
phase accumulators posing as recovery chains.

## Reference configuration (explicitly bounded)

- Modulation: **BPSK**.
- Carrier loop input: complex baseband I/Q, signed16 lanes, **SPS = 4**
  samples/symbol (Fs = 4 * Fsym).  Test waveform is mild band-limited NRZ
  ([0.25 0.5 0.25] edge smoothing, amplitude A = 0.7 FS).
- Timing loop input: real baseband signed16, **SPS in {4, 8}**
  (`cfg_sps`), same symbol format.  Integer SPS only — *no interpolation*;
  strobe quantization is +-1 sample by design.
- Signal models (generators in `models/model.py`):
  - carrier: `x[n] = A * bb[floor(n/SPS)] * exp(j*2*pi*df*n)`, df =
    residual carrier offset in cycles/sample.
  - timing: `y[n] = A * bb(floor(n/SPS*(1+ppm) + tau))`, tau = static
    timing offset in symbol units, ppm = symbol-rate offset.

## Carrier loop (rtl/carrier_loop.sv)

Datapath per accepted sample (stage A registers the input and the current
sincos(phase); stage B computes and registers results — II=1, output valid
one edge after the accepting edge):

```
Ir = sat18((I*cos + Q*sin) >>> 11)        derotate by -phase
Qr = sat18((Q*cos - I*sin) >>> 11)
e  = Ir<0 ? -Qr : Qr                       BPSK decision-directed PD
                                           (Costas sign(I)*Q form)
err32 = e <<< 13                           normalize to Q31
prop  <= err32 >>> kp_rsh                  PI loop filter (pi_loop.sv)
integ <= sat(integ + (err32 >>> ki_rsh))   clamp [-2^28, 2^28-1]
phase <= phase + sat32(fcw + prop + integ) NCO advance (mod 2^32)
```

cos/sin come from `nco.sv`: 32-bit phase accumulator, 256-point full-wave
sine reconstructed from a 64-entry quarter-wave LUT (`round(2047*sin())`,
Q1.11, max LUT error ~1.2e-3 FS).  Loop delay is 3 samples (error of
sample n reaches the NCO phase used by sample n+3); the phase a sample is
derotated with is always the pre-update accumulator value, so handshake
stalls only stretch wall-clock time, never corrupt state.  `freq_est`
exports the last applied increment (`fcw + corr`, signed32, units
cycles/sample * 2^32).

PI structure: prop + integ, both right-shifted versions of the Q31 error.
Effective small-signal gains (cycles/sample per unit normalized error):
`Kp = 2^(-4-kp_rsh)`, `Ki = 2^(-4-ki_rsh)`.  Defaults kp_rsh=4, ki_rsh=8
(Kp ~= 3.9e-3, Ki ~= 2.4e-4 /sample).  Verified stable region: kp_rsh in
3..10 with ki_rsh > kp_rsh and ki_rsh <= kp_rsh + 10; the `ki_rsh > kp_rsh`
rule (integrator strictly weaker than proportional) is enforced by the
config checker.  This is a verified corner, not a proof for all gains.

### Verified operating points (RTL bit-exact vs model, 88k cycles)

| case                                  | result                              |
|---------------------------------------|-------------------------------------|
| cold acquire df=+Fs/64                | lock at 1948 cyc, fe=+0.015623      |
| cold acquire df=-Fs/96                | (re)lock, fe=-0.010417              |
| cold acquire df=+Fs/32 (pull edge)    | lock at 12938 cyc, fe=+0.031250     |
| fcw preset, df=+Fs/20                 | lock at 691 cyc, fe=+0.050007       |
| cold df=+Fs/16 (out of pull range)    | lock never asserts; |fe|<0.003      |
| offset step -Fs/96 -> +Fs/96          | stays locked                        |
| illegal cfg x6                        | atomic reject, cfg_error            |

Pull-in range: |df| <= **Fs/32** guaranteed (verified both signs at
smaller offsets, and +Fs/32 at the boundary).  Between Fs/32 and Fs/16
acquisition is marginal/seed-dependent (hang-off possible, may take
>10^4 samples or not lock).  At |df| >= Fs/16 the loop cannot even hold
(per-symbol rotation approaches 90 deg: Costas quadrant ambiguity) — cold
acquisition fails gracefully: lock stays 0, freq_est bounded, output
keeps streaming.  An fcw preset within the pull residual of the true
offset acquires fast (verified to Fs/20 with exact preset).

Post-lock residual: mean |freq_est - df| < 2e-4 Fs; mean |Qr| ~719 codes
(~2% FS) at A=0.7; decision BER on sign(Ir) at symbol centres = 0 errors
/1164 decisions.  **Inherent +-180 deg phase ambiguity** (standard for
BPSK Costas): the test resolves polarity once, then counts errors;
absolute phase needs a preamble or differential coding.

## Timing loop (rtl/timing_loop.sv)

```
step0 = 2^16/SPS                    (16384 for SPS=4, 8192 for SPS=8)
corr  = clamp(prop + integ, +-step0/4)      tracked rate offset bound
step  = step0 + corr
acc  <= acc + step                  symbol-phase accumulator (mod 2^16)
half  = acc crosses 0x8000          midpoint sample m_s captured
wrap  = acc crosses 2^16            decision strobe: pick<=1, pick_data<=x,
                                     pick_bit <= (x >= 0)
on wrap:  e = (x - s_prev>0 ? +m_s : <0 ? -m_s : 0)   Gardner TED,
                                                     sign(diff)*mid
          err32 = e <<< 13;  PI update (once per symbol);
          s_prev <= x;  rate_est <= corr
```

The Gardner TED runs at the wrapped symbol rate; `have_mid` squelches the
first error until a midpoint sample exists.  Pick rule: `pick` marks the
first sample at-or-after the estimated optimum instant; residual pick
jitter is +-1 input sample (verified: pick spacing mean exactly SPS,
positions alternate between two adjacent residues under dither).  No
interpolator — this is the documented design choice for integer SPS.

Verified (50k cycles, RTL bit-exact vs model):

| case                        | result                                   |
|-----------------------------|------------------------------------------|
| SPS=4, tau=+0.37T           | lock at 1708 cyc, 0 errors / 400 picks   |
| SPS=8, tau=-0.20T           | lock at 3543 cyc, 0 errors / 300 picks   |
| SPS=4, rate offset +4%      | tracked, rate_est=+859 (nominal +655)    |
| 1200 transition-free samples| no hang, pick keeps firing (~1/SPS)      |
| recovery after T4           | 0 errors / 400 picks                     |
| illegal cfg x6              | atomic reject, cfg_error                 |

Trackable rate-offset bound by construction: |corr| <= step0/4 => +-25%
symbol-rate error tolerated mechanically; the *verified* window is +-4%
(fine within loop bandwidth; wider tracking not claimed).  Jitter
tolerance: strobe lands within +-1 sample of the ideal instant — at SPS=4
that is +-T/4 phase quantization, fine for the shaped-NRZ reference
waveform (0 BER verified); tighter decisions need SPS=8 (+-T/8) or an
interpolator (out of scope).

## Lock detector (rtl/lock_det.sv, shared)

Leaky magnitude integrator `lavg += ((mag<<6) - lavg) >>> 6` (Q18.6,
TC ~64 updates), compared at `lavg>>>6 < lthr`.  `cnt` counts consecutive
below-threshold updates (saturating 255), `lock = cnt >= ln`.  `lavg`
arms at maximum on reset/clear — lock can only be earned by sustained low
error, never asserted by warmup.  Lock thresholds are amplitude/noise
dependent: defaults (carrier lthr=2500, timing lthr=10000) are tuned for
the A=0.7 reference waveform; heavier noise needs a higher lthr or lock
won't assert even though frequency/timing converge (verified: sigma=3000
noise still tracks correctly but needs lthr>~2500).

## Configuration interface

`cfg_valid && cfg_ready` commits atomically; `cfg_ready = !cfg_pend` —
one request in flight; `cfg_done` pulses one edge after accept,
`cfg_error` additionally when rejected.  Fields are sampled at the accept
edge so the commit is atomic even if the requester drops them early.
`cfg_clear` re-zeros loop state (integrator, proportional term, lock
detector; carrier keeps `phase`, timing also clears `acc`, `s_prev`,
`m_s`, `have_mid`).

Illegal (whole request rejected, nothing committed):
- carrier: `ki_rsh <= kp_rsh`, `|fcw| > 2^30`, `lthr < 8`, `ln < 4`
- timing: `sps_code > 1` (only 4/8), `ki_rsh <= kp_rsh`, `lthr < 8`,
  `ln < 4`

## Stream / reset contract

Single `clk`, synchronous active-low `rst_n`.  carrier_loop:
`s_tdata`/`s_tvalid`/`s_tready` in, `m_tdata`/`m_tvalid`/`m_tready` out,
`s_tready = !m_tvalid || m_tready` (and rst_n); a stall freezes every
register — the loop simply pauses, which is correct for a stream of
held real-time samples (backpressure holds samples; it does not drop
them).  timing_loop is an always-ready real-time sink (`s_tready = 1`);
`pick`/`pick_data`/`pick_bit`/`lock`/`level`/`rate_est`/`phase_out` are
flag outputs, no backpressure.

Limitation worth noting: both loops are *sample-synchronous*.  With a
continuous stream this is the standard architecture.  Under
`m_tready`-stall or input-gap the loop state freezes; when the stream
resumes the pipeline alignment can shift the loop delay by +-1 sample —
harmless inside the verified pull range but it makes pull-edge
acquisition time pattern-dependent.

## Resources (isolated synth_gowin -noalu, no -family)

| module       | LUT1-4 | +MUX2_LUT5/6 | FF  | DSP | BRAM |
|--------------|--------|--------------|-----|-----|------|
| carrier_loop | 1073   | 142 / 2      | 388 | 4   | 0    |
| timing_loop  | 725    | 84 / 0       | 270 | 0   | 0    |
| nco          | 242    | 25 / 2       | 32  | 0   | 0    |
| pi_loop      | 473    | 77 / 0       | 64  | 0   | 0    |
| lock_det     | 132    | 11 / 2       | 33  | 0   | 0    |

4 DSP = the derotation complex multiply (4x MULT18X18); the LUT index
multiply was deliberately avoided (case-ROM) to stay at 4.  Inside the
<=15K LUT / <=4 DSP board budget with large margin.

## Limitations (explicit)

- BPSK reference config only — not a general multi-modulation engine.
  QPSK would need the quadriphase Costas PD; higher-order needs a
  different detector.
- Carrier phase ambiguity +-180 deg: absolute phase requires
  preamble/differential encoding.
- Timing TED is blind without data transitions: lock may assert on a
  transition-free input at whatever phase it holds (documented);
  recovery verified on transition return.
- No interpolation: timing decisions quantize to +-1 input sample.
- Integrator can wind to its clamp during a persistent out-of-range
  offset; recovery afterwards is bounded by the clamp magnitude
  (2^28 in fcw/acc units).
- Lock thresholds are amplitude/noise dependent (see above).
- Simulation + isolated synthesis evidence only; no routed timing, no
  board run.

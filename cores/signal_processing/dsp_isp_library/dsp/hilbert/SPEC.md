# DSP12 Hilbert analytic-signal core (`hilbert_core`)

Signed16 Q1.15 real input; produces the analytic pair (I,Q), envelope,
instantaneous phase and instantaneous frequency. Accept initiation
interval is **II = ROUNDS+1 = 5 clocks** for the default `PAIRS=16`,
`LANES=4` configuration; accept-to-valid latency is **26 clocks** without
backpressure. Single `clk`, synchronous active-low `rst_n`.

## Analytic FIR and I/Q alignment

The Q path is an odd-length antisymmetric FIR of `TAPS=4*PAIRS-1` taps,
`PAIRS=16` by default (63 taps). Nonzero taps sit at odd offsets from the
center `C=2*PAIRS-1=31`; even offsets and the center are identically zero
for an ideal Hilbert transformer and are not computed:

```
Q[n] = sum_{j=0}^{p-1} c_j * ( x[n-C+d_j] - x[n-C-d_j] ),  d_j = 2j+1
I[n] = x[n-C]
```

`c_j` is the low-index tap of antisymmetric pair `j` (the high tap is
structurally `-c_j`, so antisymmetry is exact by construction). The real
path is aligned by the fixed group delay `C=(TAPS-1)/2` — the I output is
the input delayed exactly 31 samples, in step with Q for every supported
configuration, since `active_pairs` only zeroes outer pairs and never
moves the group delay. Startup history is zero (`x[k<0]=0`); the first
`TAPS-1=62` outputs are the documented startup transient.

### Shared-multiplier schedule

`LANES` (parameter, 1..4) signed multipliers evaluate `LANES` pair
products per clock for `ROUNDS=ceil(PAIRS/LANES)` rounds after each
accepted sample; pair differences are registered on accept and the
accumulator is 44-bit. One nearest-even rounding (/32768) and signed16
saturation happen once at the end, setting `clip`. `LANES<=4` keeps the
whole core at `<=4` multiplier operators (the envelope uses a shift/add
constant), so a `synth_gowin -noalu` build stays within the <=4
DSP-class budget; with `-nodsp` the same operators become LUT
multipliers. II is `ROUNDS+1` for the given (PAIRS,LANES); a finished
result waits in the output register `postv` under backpressure and is
never overwritten. Delay line and all pipeline registers are flops; no
BRAM is claimed.

## Output word (paired I/Q)

One 80-bit `m_tdata` per accepted input:

`{ freq_s16, phase_u16, env_u16, q_s16, i_s16 }`  (MSB→LSB),
`m_tuser = { zero, clip }`  (`m_tuser[1]=zero`, `m_tuser[0]=clip`).

`phase` is unsigned brads: `phase/65536` cycles in `[0,1)` i.e.
`[0,2*pi)`. `freq` is signed brads: `freq/65536` cycles/sample in
`(-0.5,0.5]`. `env` is unsigned16 sample-LSB amplitude.

## Envelope contract

`env = RNE( x_f * ENV_C / 2^19 )` where `x_f` is the x-path of a
16-iteration vectoring CORDIC (sigma=+1 for `y>=0` else `-1`, inputs
scaled <<4) run on `(|I|,|Q|)`, and `ENV_C=19898` normalizes the CORDIC
gain `K=1.64676` via shift/add (no multiplier). Measured: relative error
<=0.04% for magnitude >2000, <1.7 LSB absolute everywhere, saturated at
65535.

## Phase contract and zero amplitude

First-octant reduce: `a=min(|I|,|Q|)`, `b=max(|I|,|Q|)`; a 17-step
restoring divider yields `r=(floor(a*2^17/b)+1)>>1` in `0..65536`; a
257-entry atan table with linear interpolation gives the octant angle,
then octant/quadrant remap gives full-circle phase. Measured maximum
phase error ~1.05 brads (~0.006 deg) for magnitude >=32.

**Zero amplitude**: for `I=Q=0`, `phase=0`, `freq=0`, `env=0`, and
`m_tuser[1]=1`. Small nonzero amplitudes still produce defined outputs
with proportionally larger relative quantization.

## Frequency and unwrap rule

`freq[n] = wrap16(phase[n]-phase[n-1])`: the unsigned 16-bit difference
reinterpreted as signed, i.e. the *smallest signed step* between
consecutive phases (steps >+0.5 cyc/sample alias to negative and vice
versa). The first output after reset or a cleared configuration emits
`freq=0`; zero-amplitude samples emit `freq=0` while `prev_phase` still
tracks the emitted phase sequence.

## Valid band and degradation

Qualified band for the default 63-tap Blackman configuration:
**0.05..0.45 cycles/sample**. Measured on the quantized coefficients:
|H| within +-0.003 dB in-band; single-tone envelope error <0.2% and
instantaneous-frequency error <2e-5 cyc/sample. Outside the band the
FIR gain rolls off (-0.3 dB at 0.03/0.47, -1.7 dB at 0.02/0.48,
-6.2 dB at 0.01/0.49) and the residual negative-frequency image makes
envelope and frequency oscillate — recorded, not an error. User-loaded
coefficients carry no automatic spectral guarantee.

## Stream, configuration, reset

- `s_tready = rst_n && accept_idle && !cfg_valid`: the source may feed
  whenever the FIR MAC is idle, independently of downstream ready. The
  measurement pipeline advances on `!m_tvalid || m_tready`;
  `m_tdata/m_tuser` hold stable while `m_tvalid && !m_tready`.
- Atomic config: `cfg_valid` blocks input, waits for an empty pipeline
  (`cfg_ready`), then applies `cfg_pairs` (1..PAIRS), `cfg_coeffs`
  (PAIRS x signed18, `c_j` at bits `18j`), and `cfg_clear` in one edge.
  `cfg_done` pulses per accepted request; `cfg_pairs=0` or `>PAIRS`
  pulses `cfg_error` and changes nothing. Legal config without clear
  retains history; `cfg_clear` empties history and unwrap state.
- Reset clears all valids, history-validity, output and config state;
  defaults are `pairs=PAIRS`, `LANES` unchanged (static), the generated
  63-tap coefficient set. No in-flight sample survives reset or clear.

Supported static range: `1<=PAIRS<=32`, `1<=LANES<=min(4,PAIRS)`
(checked at elaboration); `DEFAULT_COEFFS` must be regenerated
consistently when `PAIRS!=16`.

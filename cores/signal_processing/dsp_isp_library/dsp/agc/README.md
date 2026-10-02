# DSP-07 AGC (automatic gain control)

Feed-forward signed16 streaming AGC: leaky mean-|x| energy estimate,
octave-code (1/8-octave ~0.75 dB steps) log-domain gain loop with
shift-only attack/release/estimator time constants, linear-slew mode,
mute/bypass, gain bounds, saturating output with a sticky clip flag, and
SOF(`tuser`)/EOL(`tlast`) marker pass-through.  See SPEC.md for the exact
gain law, code units, rounding, configuration and error contract.

II=1, fixed 3-edge latency, globally stalled pipeline, fabric registers
only (no RAM).  There is no routed timing or physical board acceptance
claim.  The packed config port is an internal interface, not a board pin
mapping.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/dsp/agc/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/agc/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/agc/tests/synthesize.py
```

Models use pure Python stdlib.  RTL and synthesis scripts select the
repository OSS CAD Suite (`iverilog -g2012`, `vvp`,
`yosys synth_gowin -noalu -family gw2a`).

## Interfaces

- `s_tdata/s_tvalid/s_tready` + `s_tuser`/`s_tlast`: signed16 sample
  stream with SOF/EOL delimiters; one output beat per accepted sample.
- `m_tdata/m_tuser/m_tlast/m_tvalid/m_tready`: gained output; fields hold
  under stall; markers carried with their sample.
- `cfg_valid/cfg_ready` + fields (target, gmin/gmax, attack/release/est
  shifts, mode, mute, bypass, clear): atomic, accepted only with an empty
  pipeline; `cfg_done`/`cfg_error` pulse; illegal target>120 or gmin>gmax
  rejects the whole request.
- Sideband: `clip_sticky` (set on gain-path saturation, cleared by reset
  or accepted config), `env_code[6:0]` (current level code),
  `gain_code[9:0]` (current integer gain code, signed).

## Numerics summary

- Level code c -> (c-120)*0.7526 dBFS; gain code gc -> gc*0.7526 dB.
- Gain applied as mantissa LUT (8 entries, <=0.25 LSB error) plus octave
  shift; two RNE stages, signed16 saturate -> clip flag.
- Loop update rate is per accepted sample; stall cycles do not advance
  state, so results are wall-clock invariant.

## Evidence

- `evidence/model_validation.json`: level-code monotonicity 1..32768,
  mantissa LUT <=0.25 LSB, float-AGC tail-RMS agreement (worst rel err
  ~0.11), attack>release asymmetry, constant-slew check, mute/bypass,
  gain-bound clamps, exact convergence (no deadband), config validation,
  cycle-oracle equivalence on 2000 fuzzed samples.
- `evidence/rtl_*/summary.json`: 8094 cycle-exact comparisons, 3879
  accepted samples / 3836 emitted beats, 73 SOF/EOL marker pairs, 26
  config accepts, 5 illegal rejects, 22 mid-stream resets, 1083 stalled
  output cycles; 12 checker mutations (data, valid, ready, cfg_ready,
  markers, done, error, clip_sticky, env_code, gain_code, order) all
  rejected.
- `evidence/synth_*/summary.json`: `synth_gowin -noalu -family gw2a`.

| resource | count |
|---|---:|
| LUT1-4 | 1187 |
| FF | 177 |
| DSP-class | 1 (MULT18X18) |
| BRAM | 0 |

Within the <=15K LUT / <=4 DSP delivery budget; no BRAM.  Integration,
routed timing, physical capture and production acceptance require separate
qualification.

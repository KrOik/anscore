# DSP13 shared Goertzel bank

Runtime-configurable single/multi-frequency tone detection: 1..4 frequency
bins per block, block length N=1..256, per-sample window, unsigned80 power
threshold and per-bin detect flag. See SPEC.md for the exact coefficient,
window, rounding, saturation, configuration and error contract.

This is a serialized shared-multiplier design: one signed 48x48 shift-add
multiplier (48 steps) serves the window product, the per-bin recurrence and
the four terminal products. **No II1 or streaming-rate claim.** There is no
routed timing or physical board acceptance claim. The packed configuration
port is an internal interface, not a board pin mapping.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/dsp/goertzel/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/goertzel/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/goertzel/tests/synthesize.py
```

Models use pure Python stdlib. RTL and synthesis scripts select the
repository OSS CAD Suite (`iverilog -g2012`, `vvp`, `yosys synth_gowin -noalu
-family gw2a`).

## Interfaces

- `s_tdata/s_tvalid/s_tready`: signed16 sample stream. One block consumes
  exactly N samples; input is accepted only in WAIT at the per-sample point.
- `m_power[79:0], m_bin[1:0], m_last, m_detect, m_error, m_valid/m_ready`:
  one tagged result per configured bin, emitted in bin order after the Nth
  input. All bins are emitted before the next block accepts input. Output
  fields hold while `m_ready` is low.
- `cfg_valid/cfg_ready` + `cfg_n, cfg_bins, cfg_coeffs[75:0],
  cfg_window[4095:0], cfg_thresholds[319:0]`: atomic update accepted only at a
  clean block boundary with no pending output. Illegal fields reject the whole
  request (`cfg_done`+`cfg_error` pulse; configuration retained). Asserting
  `cfg_valid` blocks new input at the boundary, so the host must finish the
  current block first; mid-block assertion is held, never accepted early.
- Single `clk`, synchronous active-low `rst_n`: aborts block/output and
  selects N=1, one DC bin (c=+2), unity window, zero threshold.

## Throughput / block-end compute time (measured, no stalls)

- Per accepted sample: `51 + 50*bins` cycles before the next sample can
  handshake (one 50-cycle shared-multiplier pass for the window product,
  one 50-cycle pass per configured bin for the recurrence, plus the accept
  edge).
- First bin output (`m_valid` rise): `last_input + 251 + 50*bins` cycles.
  Measured deltas: 301/351/401/451 cycles for 1/2/3/4 bins.
- Subsequent bins: one output rise every 201 cycles (4 multiplies + 1 output
  cycle); downstream stalls only add delay, never reorder or drop results.
- Minimum block pitch: `N*(51 + 50*bins) + bins*201` cycles. Worst case
  N=256, bins=4: 256*251 + 804 = 65060 cycles (~2.4 ms at 27 MHz).

## Numerics

- Windowed sample `wx = RNE(x*w/32768)`; recurrence
  `s = wx + RNE(c*s1/65536) - s2` on signed40 states; terminal
  `P = s1^2 + s2^2 - RNE(c*s1/65536)*s2` clamped to unsigned80.
- State-growth analysis (SPEC): |s| <= (32768+0.5)*N*(N+1)/2 < 2^31 for
  N<=256, |c|<=2; signed40 has ample guard bits, so the saturation and the
  unsigned80 power clip exist but are unreachable with legal parameters.
  `m_error` therefore stays 0 in all legal operation; mutation tests prove
  the checker would catch a wrong flag.
- `m_detect = (clipped_power >= threshold[bin])`.

## Evidence

- `evidence/model_validation.json`: float Goertzel, bit-exact model and the
  independent direct-DFT comparison required by DSP13. 109 bin cases across
  N, windows, on/off-bin tones, extremes and noise. Worst relative error on
  significant bins 6.4e-4; absolute errors inside the documented conservative
  bound `8*B*delta + 2*delta^2 + 0.5*B`, `delta=N(N+1)/4`,
  `B=(32768.5)*N(N+1)/2`.
- `evidence/rtl_20260925_102500_027163/`: 501014 cycle-exact comparisons,
  78 blocks, 2694 accepted samples, 167 emitted results. Covers the reset
  default, all N/bins/window sweep points, on/off-bin tones, zeros, full
  scale, noise, per-bin thresholds, unused-slot insensitivity, 7 illegal
  atomic-reject cases with retained-config proof, cfg_valid held mid-block,
  mid-block and stalled-output resets, long output stalls, random
  valid/ready fuzz and a 14-case randomized soak. 12 mutations (power,
  valid, s_ready, cfg_ready, detect, bin, last, error, cfg_done, cfg_error,
  output order, stimulus) are all rejected.
- `evidence/synth_20260925_102204_642094/`: `synth_gowin -noalu -family gw2a`.

| resource | count |
|---|---:|
| LUT1-4 | 8011 |
| FF | 5485 |
| DSP-class | 0 |
| BRAM | 0 |
| wide mux | 638 |

The 256-entry window array and 4x19 coefficient/4x80 threshold registers are
plain flip-flops (the IBUF-heavy cfg_window port is an internal config bus).
Within the <=15K LUT / <=4 DSP delivery budget; no BRAM claim.

## RTL change note

The inherited `rtl/goertzel_bank.sv` used `bin`/`bins` as internal register
names, which are reserved SystemVerilog keywords and failed `iverilog -g2012`.
They were minimally renamed to `bin_i`/`nbins`; port names (`m_bin`,
`cfg_bins`) and all behavior are unchanged. Source SHA256 after the fix:
`ee3f9a51e6f05dfb5a053dd2585abd4c468ce62a5a6146b1c32cd35081b67bb4`.

Historical evidence is retained. Integration, routed timing, physical capture
and production acceptance require separate qualification.

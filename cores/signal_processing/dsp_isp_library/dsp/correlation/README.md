# DSP-06 correlation / matched-filter stream

Streaming sliding correlation and matched filtering of signed real or
complex frames against a runtime-configurable template: 1..64 signed16
(re,im) taps, template conjugation, correlation/convolution direction,
VALID and FULL block-tail policies, per-position full-precision outputs and
a per-frame argmax summary. See SPEC.md for the exact arithmetic, marker,
tail, configuration and error contract.

This is a serialized shared-datapath design: two signed 16x16 multipliers
serve the tap MAC (ntaps steps per output in real mode, 2*ntaps in complex
mode). **No II1 or streaming-rate claim.** No routed timing or physical
board acceptance claim; the packed configuration port is an internal
interface, not a board pin mapping.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/dsp/correlation/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/correlation/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/correlation/tests/synthesize.py
```

Models use pure Python stdlib. RTL and synthesis scripts select the
repository OSS CAD Suite (`iverilog -g2012`, `vvp`, `yosys synth_gowin -noalu
-family gw2a`).

## Interfaces

- `s_tdata[31:0]/s_tvalid/s_tready + s_tuser/s_tlast`: complex `{im,re}`
  signed16 samples delimited into frames by SOF/EOL markers. Input is
  accepted only in the idle state between computations; a pending output or
  config request holds the stream.
- `m_tdata[95:0]={im,re}/m_pos[15:0]/m_tuser/m_tlast/m_valid/m_ready`: one
  correlation value per emitted lag position; tuser/tlast bracket each
  frame's output group. Fields hold while stalled.
- `p_pos/p_tdata/p_mag/p_error/p_valid/p_ready`: per-frame argmax summary
  (earliest position wins |re|+|im| ties), emitted after the frame's last
  data beat.
- `cfg_valid/cfg_ready` + `cfg_ntaps/cfg_mode/cfg_tail/cfg_taps[2047:0]`:
  atomic template/mode update at clean frame boundaries only; illegal
  fields reject the whole request with `cfg_done`+`cfg_error`.
- Single `clk`, synchronous active-low `rst_n`: aborts frame/output and
  selects ntaps=1 real VALID tap0=+32767 (identity-scaled passthrough).
- `marker_error`: sticky protocol flag for missing/misplaced SOF, unclosed
  frames and position-counter overruns; cleared only by reset.

## Throughput / latency (measured, no stalls)

- steps = ntaps (real) or 2*ntaps (complex); sample accept pitch steps+2.
- Output `m_valid` rises `accept + steps + 1` cycles; consecutive rises are
  steps+2 apart for sample-driven positions and steps+1 for tail positions.
- `p_valid` rises one cycle after the last data beat is accepted.

## Numerics

- Exact integer arithmetic, no rounding or saturation: bound
  `|re|,|im| <= ntaps*2^31 <= 2^37` inside signed48 accumulators.
- dir=0 correlates against the uploaded template order (peak at the
  trailing-edge lag); dir=1 correlates against the reversed sequence.
- conj applies x*conj(w) per tap, complex mode only.
- Argmax proxy is |re|+|im|, not |y|^2; hosts needing squared magnitude can
  re-rank from the streamed full-precision outputs.

## Evidence

- `evidence/model_validation.json`: 64 frame cases across ntaps 1..64,
  real/complex, both directions, conj, both tail modes, extremes and
  embedded-template recovery; bit-exact model vs float direct sum (exact)
  vs an independent FFT-convolution implementation (worst error 5.8e-6).
- `evidence/rtl_20260925_170801_526041/`: 12483 cycle-exact comparisons,
  43 frames, 676 accepted samples, 543 emitted beats, 46 peak summaries.
  Covers the reset default, all mode/direction/tail sweep points, embedded
  detection in both directions, complex conjugate matched filtering, a
  VALID underlength error frame, unused-slot insensitivity, 5 illegal
  atomic-reject cases with retained-config proof, cfg_valid held mid-frame,
  mid-frame and stalled-output/peak resets, long output stalls, marker
  faults with sticky-flag recovery, random valid/ready fuzz and a 14-frame
  randomized soak. 16 mutations (m_data, m_valid, m_pos, m_last, m_user,
  p_valid, p_data, p_mag, p_error, s_ready, cfg_ready, cfg_done, cfg_error,
  marker_error, output order, stimulus) are all rejected.
- `evidence/synth_20260925_170903_160691/`: `synth_gowin -noalu -family gw2a`.

| resource | count |
|---|---:|
| LUT1-4 | 6601 |
| FF | 4700 |
| DSP (MULT18X18) | 2 |
| BRAM | 0 |
| wide mux | 257 |

History (2x64x16) and template (2x64x16) are plain flip-flops; the
2048-bit `cfg_taps` port is an internal config bus (2101 IBUFs are pad-cell
artifacts of top-level mapping, not a pin claim). Within the <=15K LUT /
<=4 DSP delivery budget; no BRAM used. Integration, routed timing, physical
capture and production acceptance require separate qualification.

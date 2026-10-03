# DSP-05 spectrum pre/post processing

Family of four II=1 stream cores for spectrum conditioning around an FFT:
`window_mult` (unity/Hann/Hamming/Blackman/custom window multiply),
`mag_squared` (complex I/Q power), `block_accum` (block sum and mean),
`peak_search` (block maximum to index+magnitude record). See SPEC.md for
data formats, bin ordering, coherent-gain and amplitude-scaling contracts,
rounding rules and the atomic-config semantics.

Status: isolated model, RTL simulation and mapped synthesis passed. **No
P&R, routed timing, board or chain acceptance.** Python is stdlib only.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/dsp/spectrum/models/gen_window.py --emit-rom cores/signal_processing/dsp_isp_library/dsp/spectrum/rtl/window_cos_rom.sv
python cores/signal_processing/dsp_isp_library/dsp/spectrum/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/spectrum/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/spectrum/tests/synthesize.py
```

`rtl/window_cos_rom.sv` is generated and checked in; regenerate it with the
first command. `gen_window.py --type {hann,hamming,blackman} --n N` emits
the signed18 Q3.15 upload table, measured coherent gain and the amplitude
correction hint as JSON. RTL scripts use the repository OSS CAD Suite
(`iverilog -g2012`, `vvp`, `yosys synth_gowin -noalu -family gw2a`).

## Evidence

- `evidence/model_20260925_101937_965579/`: float vs bit-exact window error
  <=4.8e-5 of coefficient, measured CG (hann 0.5, hamming 0.540009,
  blackman 0.420013), bin-centered DFT peak through window->power->peak at
  model level (earliest-index tie on symmetric real-signal bins), rounding
  tie cases, illegal configs.
- `evidence/rtl_20260925_102703_920325/`: per-cycle fixtures compared every
  cycle (held-output stability included): window_mult 12561 cycles,
  mag_squared 3819, block_accum 9386, peak_search 1775. Covers every window
  type, N=16..4096, shifts -8..15, custom upload incl. partial-table
  backpressure and overflow backpressure, random valid/ready fuzz,
  mid-stream reset, illegal whole-field rejects, extremes/zero/impulse/
  constant/random vectors. 5 mutation rejections per core (data, valid,
  ready, user flag, cfg_done).
- `evidence/synth_20260925_102745_583589/`: `synth_gowin -noalu -family
  gw2a` per top. No latches or warnings beyond the usual ABC note.

| core | LUT1-4 | FF | MULT18X18 | DPX9B | wide mux |
|---|---:|---:|---:|---:|---:|
| window_mult | 838 | 292 | 3 | 6 | 86 |
| mag_squared | 417 | 188 | 2 | 0 | 28 |
| block_accum | 416 | 100 | 0 | 0 | 61 |
| peak_search | 317 | 149 | 0 | 0 | 65 |

window_mult BRAM = quarter-wave cosine ROM plus the 4096-entry custom
table; all four cores are far under the 15K LUT / 4 DSP image budget.

Source SHA256 (see ip_manifest.json for the full map): window_mult.sv
`8e157a8dd8a2a10a08a0810ba2a2a26a80f80026d7d9e621b42f7544f2939835`.
Historical evidence is retained; integration and physical acceptance are
separate gates.

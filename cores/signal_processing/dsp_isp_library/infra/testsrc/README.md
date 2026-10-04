# INFRA-07 stream test-source / test-sink checker cores

Reusable bring-up and regression generators/sinks for the DSP/ISP library's
`tdata/tvalid/tready (+tuser=SOF, tlast=EOL)` stream contract. Six synthesizable
cores plus pure-stdlib Python bit-exact models:

| module | role |
|---|---|
| `rtl/prbs_source.sv` | PRBS-16 Fibonacci LFSR word source (seedable, finite/unlimited word count) |
| `rtl/tone_source.sv` | multi-tone (≤4) and swept-tone signed-16 Q1.15 generator |
| `rtl/image_pattern_source.sv` | sequence/gradient/checker/bar image frames with SOF/EOL markers |
| `rtl/backpressure_sink.sv` | controlled-backpressure sink (always-ready / LFSR-threshold / run-stall) |
| `rtl/crc32.sv` | streaming CRC-32 IEEE word accumulator (transport aid only) |
| `rtl/stream_sink_checker.sv` | count/sequence/SOF-EOL/CRC checker with sticky flags and first-error index |

All cores use single-clock synchronous active-low reset, hold `m_tvalid` and
payload stable under backpressure, and take atomic `cfg_valid/cfg_ready/
cfg_done/cfg_error` configuration. Illegal configurations pulse `cfg_error` and
leave the active stream state untouched. See `SPEC.md` for the exact output
sequence, marker, packing, rounding, error-flag, trigger, and legality
contract of every core.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/infra/testsrc/tests/test_models.py
python cores/signal_processing/dsp_isp_library/infra/testsrc/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/infra/testsrc/tests/synthesize.py
```

Models are pure Python standard library (no NumPy/pip). RTL and synthesis
scripts select the repository OSS CAD Suite (`iverilog -g2012`, `vvp`,
`yosys synth_gowin -noalu -family gw2a`).

## Evidence

- `evidence/model_20260925_101956_434104/`: model self-checks — PRBS-16 period
  65535 and vectors, CRC-32 against `zlib.crc32` (`"123456789"→CBF43926`),
  tone LUT vs `math.sin` bound and sweep-up/down wrap indices, image markers
  for 1x1/2x2/7x5, backpressure determinism, checker clean-accept plus
  CRC/sequence/SOF/EOL/extra-beat mutation rejection.
- `evidence/sim_20260925_104744_748877/`: 21 iverilog fixtures — 4923
  cycle-accurate oracle comparisons covering held-output stability under
  random ready, random valid gaps, mid-stream reset, illegal configs, all
  checker mutation flags with first-error index, trigger modes, two wired
  chains (`image_pattern_source→backpressure_sink→checker`,
  `prbs_source→checker`), and three harness-negative checks proving a
  corrupted expected field is rejected.
- `evidence/synth_20260925_104830_323913/`: `synth_gowin -noalu -family gw2a`
  isolated mapping per module and alternate parameterizations.

| configuration | LUT1–4 | FF | DSP | BRAM | wide mux |
|---|---:|---:|---:|---:|---:|
| crc32 (16) | 149 | 65 | 0 | 0 | 24 |
| crc32 (8) | 119 | 65 | 0 | 0 | 25 |
| crc32 (32) | 225 | 65 | 0 | 0 | 31 |
| prbs_source | 279 | 167 | 0 | 0 | 15 |
| tone_source (MAX_TONES=4) | 3256 | 677 | 4 | 0 | 846 |
| tone_source (MAX_TONES=2) | 1844 | 469 | 2 | 0 | 460 |
| image_pattern_source (8,4096,4096) | 490 | 219 | 2 | 0 | 35 |
| image_pattern_source (16,4096,4096) | 584 | 227 | 2 | 0 | 45 |
| backpressure_sink (16) | 321 | 195 | 0 | 0 | 28 |
| backpressure_sink (8) | 328 | 187 | 0 | 0 | 36 |
| stream_sink_checker (8) | 628 | 384 | 0 | 0 | 69 |
| stream_sink_checker (16) | 691 | 400 | 0 | 0 | 75 |

Per-core usage is within the ≤15000 LUT-class / ≤4 DSP-class image budget;
`tone_source` at MAX_TONES=4 sits exactly at 4 DSP. Combined usage must still
fit the enclosing image's budget — that check belongs to the integrating core.

## Limitations

- Simulation and isolated synthesis only: no place-and-route, routed timing,
  pin fit, or board acceptance is claimed or implied.
- CRC is a transport aid, not a numerical acceptance mechanism; functional
  acceptance remains per-result comparison against the independent model.
- `tone_source` uses a 64-entry midpoint quarter-wave LUT; see SPEC.md for the
  quantization error bound versus `math.sin` (validated, not analytical).
- Checker `err_extra`/sequence models assume `tvalid` low or `tready` high per
  the library stream contract; a `tvalid` beat dropped while `tready` is low is
  a producer violation, not a checker miss.
- Trigger modes are one-cycle pulses; they are status outputs, not handshakes.

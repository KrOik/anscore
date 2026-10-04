# INFRA-04 tools inventory audit

Scope check of goal.md infrastructure item 4 (requirements.json `INFRA-04`):
浮点/定点向量工具、系数/LUT 生成、外部数据注入/导出、板测 wrapper、吞吐计数器.
This is a source/evidence inventory only — it maps what exists, it does not
promote any item to qualified. Ledger status for INFRA-04 stays unchanged;
known physical limits are called out per sub-item.

## 1. 浮点/定点向量工具 (float/fixed-point vector tooling) — COVERED (scattered, no shared library)

Host-side pure-stdlib float + bit-exact reference pairs exist per core and are
the de-facto vector tools: they generate expected vectors, quantize, and check
errors. None reads DUT output to build goldens.

- `infra/fixedpoint/models/reference.py` — shared Q-notation helpers (`rne`
  round-to-nearest-even incl. negatives, saturation, log2/exp2 tables) reused
  by `infra/fixedpoint/tests/test_models.py`, evidence `infra/fixedpoint/evidence/model_*/summary.json`.
- Per-algorithm models (float reference + bit-exact model in one file):
  `dsp/{agc,biquad,correlation,farrow,goertzel,halfband,hilbert,resampler,spectrum,statistics,stft}/models/reference.py`,
  `dsp/dc/models/dc_reference.py`, `isp/{basic_isp,bayer,histeq,ispstats,localstats}/models/reference.py`,
  `isp/{ccm,chroma,lsc}/models/model.py`, `isp/{convolution,gradient,median,morphology}/model.py`,
  `isp/scale/scale_model.py`, `infra/stream/model.py`, `infra/window/model.py`,
  `infra/asyncfifo/models/model.py`.
- Test-vector sources: `infra/testsrc/models/reference.py` + `infra/testsrc/rtl/`
  (PRBS-16 seedable, multitone/sweep Q1.15, image patterns with SOF/EOL,
  controlled-backpressure sink, CRC-32, sequence/flag checker). RTL and model
  are bit-identical; evidence `infra/testsrc/evidence/sim_*/summary.json`.
- Vector replay path: `board/dsp_chain_harness/run.py --vector-json` replays
  saved host input vectors with recomputed goldens.
- External fixed-point data import: `isp/lsc/models/gen_grid.py --import mesh.csv`
  accepts float or raw Q4.12 grids and emits packed write-port words.

Gaps (honest):
- No single shared vector file format or pack/unpack library; each board
  harness ships its own `protocol.py` with duplicated `struct` framing
  (`board/dsp_chain_harness/protocol.py`, `board/block_harness/protocol.py`,
  `board/image_harness/protocol.py`, `board/window_probe/protocol.py`,
  `board/scale_harness/protocol.py`). Functional but not one tool.
- No dedicated float-vector dump/diff CLI between model and RTL traces;
  comparison is embedded in each `test_*.py` driver.

## 2. 系数/LUT 生成 (coefficient/LUT generation) — PARTIALLY COVERED

Working generators, each emitting either a `.vh`/`.sv` include or packed
config words plus a JSON report:

| Generator | Output | Used by |
|---|---|---|
| `dsp/biquad/models/gen_coeffs.py` | packed cfg hex + gain report (Q3.15 RBJ) | `biquad_sos_stream.sv` cfg port |
| `dsp/halfband/models/gen_coeffs.py` | halfband/CIC-comp coefficients | `halfband_*.sv`, `cic_comp_fir.sv` |
| `dsp/hilbert/models/gen_coeffs.py` | Hilbert FIR taps | `hilbert_core.sv` |
| `dsp/resampler/models/gen_coeffs.py` | polyphase L/M coefficient sets | `polyphase_resampler.sv` |
| `dsp/spectrum/models/gen_window.py` | window JSON + `--emit-rom` cosine ROM | `window_cos_rom.sv`, `window_mult.sv`; reused by `stft_welch.sv` window passthrough |
| `isp/gen_csc_coeffs.py` | `csc_coeffs.vh` Q16 spec constants (601/709, full/limited, fwd/inv/gray, 8/10-bit) | `csc_stream.v` |
| `isp/scale/gen_scale_coeffs.py` | `scale_lanczos3.vh` 64-phase×6-tap + `scale_coeffs.json` | `scale_poly6_stream.v` |
| `isp/lsc/models/gen_grid.py` | `.mem` packed grid writes + `params.json`; CSV import | `lsc_stream.sv` write port |
| `isp/basic_isp/models/reference.py` `emit_gamma_vh()` | `rtl/gamma_table.vh` 33-node PWL gamma | `isp_gamma.sv` |
| `dsp/goertzel/models/reference.py` `coefficient(f)` | host-computed cfg_coeffs (not a file emitter) | `goertzel_bank.sv` cfg port |
| `isp/ccm/models/model.py` | monotone 33-node PWL tone tables validated at commit, packed by model | `ccm_stream.sv` cfg port |

Gaps:
- REUSE_AUDIT.md already flags this: generation exists for the cores shipped
  so far but there is no shared coefficient→packed-config emitter; each
  generator has its own output format.
- No generators exist where none are currently required (farrow fixed cubic,
  dc/agc/statistics/correlation/lms runtime config, histeq runtime CDF,
  chroma/convolution/morphology kernel-as-config). If those cores later need
  tables, the generator does not exist yet — remains open per ledger.

## 3. 外部数据注入/导出 (external data injection/export) — COVERED for bounded sizes

- `board/uart_injection_probe.v` + `board/tb_uart_injection_probe.sv` +
  `board/uart_injection_probe.cst`: UART T13 RX → XOR → FX2 D0 transform
  probe. `board/build_probe.ps1` builds, `board/program_probe.ps1` programs
  SRAM only.
- `board/probe_external.py`: fresh `secrets` random packet injection,
  exclusive `board_lock.py`, sigrok FX2 capture, strict per-line decode,
  cyclic-mismatch verifier. Evidence `artifacts/dsp_isp_20260925/uart_external_01`,
  `_02/verdict.json` = PASS, 373/377 fresh decoded bytes. Scope note: this
  qualifies transport only, per `board/README.md`.
- Block/stream injection+export protocols, all UART-load → synchronous RAM →
  full-rate or controlled-stall replay → output RAM → raw export (never a
  digest): `DSC1/DST1` (`board/dsp_chain_harness/`), `BLK1`
  (`board/block_harness/`), `WPR1/WPO1` (`board/window_probe/`), plus
  `board/image_harness/` and `board/scale_harness/` request/response formats.
- Remote path: `board/remote/probe_remote.py`, `run_board_remote.py`,
  `run_chain_remote.py`, `board_case_remote.py`, `probe_remote_board.py` —
  SSH (paramiko) to the bianbu board, uploads bitstream + frozen
  `protocol.py`/models, runs inject/capture/decode/verify remotely, downloads
  artifacts. Evidence under `artifacts/dsp_isp_remote_20260926/`.
- Export fidelity: raw `.sr` captures, `decoded.bin`, `expected_packet.bin`,
  `input_packet.bin`, `program.log`, `capture.log`, `verdict.json` all frozen
  per run; harnesses return every captured output word.

Gaps:
- Bounded by on-chip SRAM: ≤64 words per block request, ≤10×10-class frames.
  No bulk frame/stream path through external DDR — blocked on INFRA-06.
- Export is FX2 4 MS/s sigrok decode; no high-bandwidth export channel.
- Ledger `progress_note` stands: actual algorithm candidates showed physical
  errors; identity path is the only physically clean path so far.

## 4. 板测 wrapper (board-test wrappers) — COVERED per block, not generic

- `board/uart_injection_probe.v` — transport wrapper.
- `board/block_harness/block_harness.v` — CORE parameter selects DC / CSC
  (BITS 8/10) / identity diagnostic, MEM_IMPL inferred vs explicit DPX9B;
  shared `BLK1` envelope, config legality checks, watchdog.
- `board/dsp_chain_harness/dsp_chain_harness.v` + `chain_ram.v` — external
  64×16 sample load, DC→statistics replay, 64×136 full-result capture.
- `board/image_harness/image_harness.v` — full-frame image wrapper.
- `board/scale_harness/scale_harness.v` — scaler wrapper with BIST model
  (`bist_model.py`).
- `board/window_probe/window_probe.v` + `variants/` — sliding-window
  diagnostic wrapper.
- Drivers: `board/run_block_board.py`, `board/run_image_board.py`,
  `board/run_scale_board.py`, `dsp_chain_harness/run_board.py`,
  `window_probe/run_board.py`/`run_board_dbg.py`; `board/build_log_gate.py`
  audits build logs.

Gaps:
- No generic stream wrapper that accepts an arbitrary `s_/m_` core; every new
  core still needs its own harness RTL (the shared envelope is copied, not
  instantiated). Acceptable as delivered capability, but it is duplication,
  not a reusable wrapper.

## 5. 吞吐计数器 (throughput counters) — COVERED at harness level

- `board/dsp_chain_harness/dsp_chain_harness.v`: 32-bit RUN `cycles` counter,
  `input_count`/`output_count`, 4096-cycle watchdog; `protocol.py
  expected_cycles()` recomputes exact cycles from an independent elastic-stage
  oracle and requires equality (not a bound).
- `board/block_harness/block_harness.v` + `protocol.py`: same envelope
  (cycles/inc/outc verified per response).
- `board/image_harness/protocol.py`: `replay_cycles` + `cycles_per_pixel`
  returned and checked.
- `board/window_probe/protocol.py`: `run_cycles()` model vs measured `cycles`
  field, strict equality.
- `board/scale_harness/protocol.py`: `cycles` in response header.
- `infra/testsrc/rtl/stream_sink_checker.sv`: beat count, sequence position,
  first-error index — reusable RTL counters for stream throughput checking.
- `infra/stream/stream_stats.v` (new, INFRA-01 companion): twelve 32-bit
  saturating counters — accepted/emitted beats, source/sink stall cycles,
  tlast/tuser counts, error strobes, counted-cycle denominator, idle cycles —
  passive tap, index-addressable readout. Not yet instantiated in any harness.

Gaps:
- Cycle counters are per-harness registers, not a shared counter block wired
  into designs; `stream_stats` exists but is unintegrated.
- No sustained long-run throughput measurement on board (all runs are bounded
  bursts); no bandwidth/data-rate reporting beyond per-run cycle counts.

## Bottom line

INFRA-04 is **partially** delivered. Every sub-item has at least one working
implementation with evidence, but the capability is scattered per-module /
per-harness rather than packaged as shared tools, coefficient generation is
missing for algorithms that have not yet needed tables, injection/export is
SRAM-bounded pending INFRA-06, and throughput counting is harness-local with
`stream_stats` available but unintegrated. Nothing here changes the ledger:
the existing limitations and `progress_note` remain accurate.

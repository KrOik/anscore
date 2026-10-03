# DSP-14 `stft_welch` — STFT / Welch power spectrum

Status: **simulation-passed** (`仿真通过` candidate). Isolated Gowin mapping
done; no P&R, no board acceptance, no production integration.

Streaming Welch periodogram built entirely from existing qualified cores:

```
s_ signed16 -> 128x16 overlap ring buffer (sig_sdp_ram)
  -> window_mult (DSP-05, MAX_LOG2N=6, Hann/Hamming/Blackman/unity/custom)
  -> fft64 (sigproc_20k serialized 64-pt FFT, 768-beat compute)
  -> mag_squared (DSP-05, u32 power, RNE shift)
  -> internal 42-bit averager -> m_ u32 bin records
```

## Contract summary (see `SPEC.md` for the full contract)

- Frame N=64 fixed; hop H in {8,16,32,64} (`cfg_hop`); overlap N-H.
- Output record = K bins natural order (K=33 one-sided, 64 two-sided),
  `m_tuser={LAST,SOF}`. Bins >N/2 are negative frequencies.
- Averaging: block `A=2**cfg_avg` (0..8) or exponential `alpha=cfg_avg`
  (1..8) with 8 guard bits.
- Integer PSD units; physical `PSD[k] = P[k]*2^pshift*2^12/(fs*U_q)`
  (x2 for interior one-sided bins); exact `U_q = sum(w_q^2)` constants are
  produced by `models/reference.py: window_power_sum`.
- Honest rate: a measured 910 clk per frame through the serialized FFT, so the
  sustained input bound is `H/910` samples/clk (max ~1/14 at H=64).
  The 128-entry buffer decouples bursts only; full is pure backpressure.
- Atomic config from IDLE only; legal commit clears buffered samples,
  averager state/validity and counters; illegal fields reject whole.
- Custom window table via `coe_*` passthrough (window_mult contract);
  an incomplete table stalls loading — backpressure, not an error.

## Evidence

- `evidence/model_20260925_121418_580044/summary.json` — 47 model checks PASS (float FFT vs
  naive DFT, framing, window constants, averager math, PSD normalization,
  float-vs-bit-exact agreement, config legality).
- `evidence/rtl_20260925_120217_352013/summary.json` — 73,406-cycle
  cycle-exact fixture PASS, 16 scenario cases (all windows, all hops,
  both sided modes, block A=1..8 and exp alpha=1..8, buffer-full
  backpressure, held outputs, mid-stream reset, illegal configs, custom
  table stall/resume), 8 mutation rejections, plus a RAM_REGS=0 (DPX9B
  simulation model) run.
- `evidence/synth_20260925_120758_274774/summary.json` — isolated
  `synth_gowin -noalu -family gw2a` both RAM styles.

Measured PSD accuracy (integer output vs float model, |DFT|^2 units):
bin-aligned unity tone max rel err 2.5e-4 on significant bins; hann
inter-bin tone rel err 4.3e-3, abs err 3.4e-2 real units (~0.07% of peak).

## Resources (isolated, includes instantiated sub-cores)

| config | LUT1-4 | FF | DSP | BRAM | LUT-RAM |
|---|---:|---:|---:|---:|---:|
| RAM_REGS=1 (reg arrays) | 11920 | 7889 | 5 | 2 | 20 |
| RAM_REGS=0 (DPX9B) | 7592 | 3095 | 5 | 6 | 20 |

**DSP count is 5** (`MULT18X18`: 1 in window_mult, 4 in mag_squared's two
squares) — a board image containing this core exceeds the 4-DSP-class
budget; a LUT-multiply magnitude variant or DSP sharing would be needed.
LUT fits 15K both ways.

## Limitations

- N fixed at 64; hop only {8,16,32,64}; power-of-two averaging only.
- No fs scaling or non-power-of-two coherent-gain correction on-chip.
- Serialized FFT: no II=1; sustained input rate is bounded by H/T_frame.
- fft64 butterfly wrap is deterministic legacy behavior — near-full-scale
  complex intermediate growth can wrap (bounded for real-input frames by
  window + /2-per-stage scaling; validated vectors cover the used range).
- The reused fft64/sig_sdp_ram/tw_rom_* have a legacy clk_en/async-reset
  capable interface; the wrapper ties clk_en=1 and requires synchronous
  rst_n application (see SPEC.md).
- No P&R, timing, board or production acceptance.

## Reproduce

```
python tests/test_models.py
python tests/test_rtl.py
python tests/synthesize.py
```

# gw2a_sig_fft64

64-point radix-2 DIT FFT for Gowin GW2A-18 (Tang Primer 20K). Signed 16-bit
complex data, Q1.15 fixed point. **0 DSP cells** — the twiddle multiply is an
exact shift-add network; no `*` operator exists in the datapath. Data buffers
use synchronous register-array reads (`sig_sdp_ram`, REGS=1), and twiddle
tables use registered LUT case ROMs (`tw_rom_cos`, `tw_rom_sin`). This core
requires no memory initialization files. The existing storage choice avoids
the documented board problem with the earlier FFT DPX9B access path.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | clock (validated at 27 MHz) |
| `clk_en` | in | 1 | clock-enable; all state advances only on `clk_en` beats |
| `rst_n` | in | 1 | async active-low reset |
| `ld_en`/`ld_addr`/`ld_re`/`ld_im` | in | 1/6/16/16 | load port; write 64 samples while `busy=0` |
| `start` | in | 1 | one-beat pulse launches the transform |
| `busy`/`done` | out | 1/1 | `busy` during compute; `done` stays high until next accepted start or reset |
| `rd_en`/`rd_addr`/`rd_re`/`rd_im` | in/out | 1/6/16/16 | readout port; `rd_*` valid one `clk_en` beat after `rd_en` |

## Ordering

Host writes the 64 input samples in **natural order** (`ld_addr = n`). The core
stores them bit-reversed internally. Readback through `rd_addr` is **natural
order** `X[0..63]` — no host-side reordering is needed.

## Scaling

Every butterfly computes `(u +/- t) >>> 1`, so after 6 stages the output equals
approximately `DFT(x)/64` in Q1.15, subject to stage-wise rounding and wrapping.
Arbitrary full-scale complex inputs can overflow a 16-bit butterfly output.
Butterfly results truncate deterministically to signed 16 bits, bit-matched to
`tools/golden_model.py`.

## Timing

One butterfly per 4 `clk_en` beats; total latency is
`32 butterflies x 6 stages x 4 = 768 clk_en` beats after `start`
(~28.4 us at 27 MHz with `clk_en=1`). `done` remains high until a new
accepted start or reset; load/readout time is separate from compute latency.

## Twiddle multiply

`W64^k = cos(2*pi*k/64) - j*sin(2*pi*k/64)` quantized Q1.15 with `sin(pi/2)`
saturated to `32767`. Three signed 17-bit shift-add products use guarded
pre-adds: `(re+im)*cos`, `im*(sin-cos)` and `re*(cos+sin)`. Their low-32-bit
recombination equals the original four-product arithmetic. The complex
product is rounded half-up via `(p + 0x4000) >>> 15`.

## Validation

- Regression: `scripts/test_sigproc_fft_optimization.ps1 -OutputDir <new-dir>`.
  Checks 128 complex vectors / 8192 bins against `tools/golden_model.py`,
  baseline valid host outputs and control every cycle, clock-enable stalls, busy-time
  requests and reset recovery. All transforms take 768 enabled compute beats.
- Full-rate board harness simulation checks 2112 serialized UART bytes for
  eight vectors, including complex extrema and seeded random inputs.
- Integrated digest (FNV-1a): `53D1DDAF`.
- Full-rate physical validation: 173 frames across reprogramming, 11072 complex
  bins, all eight vectors and 768-cycle counts PASS at 27 MHz / clk_en=1.
  Baseline fails this raw-output test despite passing its timing estimate.
- The multiplier uses a balanced partial-product reduction. Internal reads
  fetch b/twiddle then a, registering three products between multiply and
  recombination. The four-beat butterfly schedule is preserved.
- Same-tool isolated synthesis: LUT1-4 4368 -> 5166; FF 2190 -> 2254;
  DSP/BSRAM 0/0. This is a correctness/throughput repair with an area cost.
  See `docs/IP_OPTIMIZATION_STATUS.md` for evidence and integration status.

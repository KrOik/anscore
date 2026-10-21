# gw2a_sig_otsu_thresh

Iterative Otsu between-class-variance threshold search over a 256-bin
histogram, for Gowin GW2A-18. Multi-cycle FSM; all multiply/divide work uses
sequential shift-add engines — **0 DSP**.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk`/`clk_en`/`rst_n` | in | 1 | clock, clock-enable, async reset |
| `start` | in | 1 | launch the search (one-beat pulse while `busy=0`) |
| `busy`/`done` | out | 1/1 | `busy` during search; `done` pulses when `thr` is valid |
| `h_req`/`h_addr` | out | 1/8 | histogram read strobe + address, driven by the core |
| `h_data` | in | 16 | `hist[h_addr]`, must be presented one `clk_en` beat after `h_req` (directly compatible with `hist256` `rd_en`/`rd_addr`/`rd_data`) |
| `thr` | out | 8 | winning threshold `t*` |
| `best_score` | out | 32 | saturated between-class-variance score at `t*` |

## Algorithm

Bit-exact vs `tools/golden_model.py`:

- Pass 1: `N = sum h[t]`, `sumT = sum t*h[t]`.
- Pass 2, per `t` in 0..255: `w0 += h[t]`, `s0 += t*h[t]`, `w1 = N - w0`;
  `den = w0*w1`; `num = |s0*N - sumT*w0|`;
  `score = (den==0 || num==0) ? 0 : min((num^2 >> 32) / den, 0xFFFFFFFF)`.
- Argmax: the **first** `t` whose score strictly exceeds the running best wins
  (ties keep the earlier threshold).
- Edge case: an empty or single-bin histogram yields `thr=0`, `best_score=0`.

Runtime is bounded by ~100k `clk_en` beats (two histogram passes plus the
per-threshold 64-bit square and divide engines) — milliseconds at 27 MHz, so
it easily interleaves with frame acquisition.

## Validation

- FNV-1a digest of `{thr, best_score}` vs golden model: `D97CE6D3`.
- Verified in `sim/tb_sig_selftest.v` and on board.

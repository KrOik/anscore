# INFRA-05 shared fixed-point arithmetic cores

Reusable arithmetic primitives for later RMS / AGC / NLMS / statistics /
geometry cores. See `SPEC.md` for the exact per-function contract: Q-notation,
RNE rounding, saturation, abnormal-input behavior, latency/II and parameter
bounds. Pure-stdlib float + bit-exact models live in `models/reference.py`.

| Module | Function | II | Latency | Key flags (m_tuser) |
|---|---|---|---|---|
| `sat_round` | RNE >> SHIFT + signed saturation | 1 | 1 | clip, inexact |
| `cplx_mac` | complex MAC run (`s_tlast` ends run) | 1 | 3 after last beat | acc-ovf, clip |
| `fp_div_iter` | signed a/b scaled 2^FB | latency | AW+FB+1 (2 if b=0) | div0, clip |
| `fp_div_pipe` | same, unrolled | 1 | AW+FB+1 | div0, clip |
| `fp_sqrt_iter` | unsigned isqrt with 2^FB scale | latency | N+1 | exact, zero |
| `fp_sqrt_pipe` | same, unrolled | 1 | N+1 | exact, zero |
| `fp_log2_iter` | log2, shift-add + LUT | latency | P+4 (3 abnormal) | abnormal |
| `fp_exp2_iter` | 2^x, shift-add + LUT | latency | P+4 | under, clip |

Iterative variants take one operation at a time (`s_tready` while idle);
pipelined variants accept every cycle unless the output slot stalls.
Measured numeric quality (exhaustive at the tested geometry): division and
sqrt are exactly RNE (<=0.5 lsb), log2 <=0.585 ulp, exp2 <=1.3e-5 relative
plus output quantization. See `evidence/model_*/summary.json`.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/infra/fixedpoint/tests/test_models.py
python cores/signal_processing/dsp_isp_library/infra/fixedpoint/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/infra/fixedpoint/tests/synthesize.py
```

Each run creates a fresh timestamped `evidence/<kind>_*/summary.json` with
PASS status, full logs, fixtures and source SHA-256. RTL and synthesis use
the repository OSS CAD Suite (`iverilog -g2012 -Wall`, `vvp`,
`synth_gowin -noalu -family gw2a`). The RTL suite checks every output every
cycle against an independent cycle oracle: extreme/zero/one/max/min/random
vectors, random valid/ready fuzz, long stalls, mid-stream resets, a
full-speed II=1 region for the pipelined variants, a small-accumulator
cplx_mac instance exercising the overflow flag, a signed-input log2
instance exercising nonpositive rejection, six corruption rejections per
instance (data, flags, valid, ready, order, count), and nine illegal static
parameter rejections.

## Isolated synthesis evidence (synth_gowin, gw2a, -noalu)

| Configuration | LUT1-4 | FF | MULT18X18 | BRAM |
|---|---:|---:|---:|---:|
| sat_round 32->16 sh15 | 45 | 19 | 0 | 0 |
| cplx_mac 16/48/32 | 740 | 459 | 4 | 0 |
| cplx_mac 16/40/32 | 638 | 427 | 4 | 0 |
| fp_div_iter 16/16/15->18 | 308 | 113 | 0 | 0 |
| fp_div_pipe 16/16/15->18 | 1359 | 1754 | 0 | 0 |
| fp_sqrt_iter 32 fb8 | 216 | 120 | 0 | 0 |
| fp_sqrt_pipe 32 fb8 | 1173 | 1165 | 0 | 0 |
| fp_log2_iter 16 fb12 g6 | 343 | 89 | 0 | 0 |
| fp_exp2_iter 16 fb12 g6 out13 | 330 | 85 | 0 | 0 |
| fp_exp2_iter 16 fb12 g6 out28 | 359 | 100 | 0 | 0 |

Mapped-logic counts only (IBUF/OBUF/VCC/GND excluded from LUT/FF totals as in
other library tables); no placement, routing, or 27 MHz timing claim. The
complex MAC needs 4 Gowin multipliers per instance — a system image using it
plus other DSP cores must budget MULT18X18 carefully (device target is <=4
DSP-class per delivered image). The log2/exp2 units are multiplier-free.

## Status

Isolated model/RTL/synthesis verification passed. No P&R, no board, no
production-chain acceptance. Runtime configuration is not part of these
cores (static parameters only); illegal parameter combinations are rejected
at elaboration or at time 0.

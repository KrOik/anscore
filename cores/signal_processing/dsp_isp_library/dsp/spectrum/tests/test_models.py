"""Independent model validation for the DSP-05 spectrum cores.

Compares the bit-exact integer model against an independent floating-point
reference, checks window quantization error and coherent gain, runs
bin-centered DFT checks through the window -> mag_squared -> peak_search
chain at model level, and exercises rounding/tie rules. Writes a timestamped
evidence summary.
"""
import sys, json, random, math, cmath
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
import reference as R

BASE = Path(__file__).resolve().parents[1]
OUT = BASE / 'evidence' / ('model_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
rng = random.Random(0xD05)
report = {'status': 'PASS', 'checks': []}

# --- window coefficient quantization error vs exact periodic windows -------
worst = 0.0
for wt in range(4):
    for log2n in range(4, 13):
        N = 1 << log2n
        for n in range(N):
            err = abs(R.window_coeff(n, log2n, wt) / 32768
                      - R.float_window(n, N, wt))
            worst = max(worst, err)
assert worst < 1.2e-4, worst
report['checks'].append({'kind': 'window_quant_error', 'max_abs': worst})

# --- coherent gain of generated tables -------------------------------------
cgs = {}
for wt, name in [(0, 'unity'), (1, 'hann'), (2, 'hamming'), (3, 'blackman')]:
    for log2n in range(4, 13):
        t = R.gen_window_table(log2n, wt)
        cg = R.coherent_gain(t)
        a0 = R.WIN_FLOAT.get(wt, (1.0, 0, 0))[0]
        assert abs(cg - a0) < 5e-5, (wt, log2n, cg)
    cgs[name] = cg
report['checks'].append({'kind': 'coherent_gain', 'measured': cgs})

# --- windowed sample path vs float -----------------------------------------
worst = 0.0
worst_rel = 0.0
for wt, log2n, sh in [(0, 4, 0), (1, 6, 0), (2, 8, 3), (3, 12, -4),
                      (1, 4, -8), (3, 5, 15)]:
    N = 1 << log2n
    xs = [rng.randrange(-32768, 32768) for _ in range(2 * N + 7)]
    fixed = R.window_stream(xs, log2n, wt, sh)
    for i, (y, clip) in enumerate(fixed):
        n = i % N
        f = xs[i] / 32768 * R.float_window(n, N, wt) * (2.0 ** -sh)
        fs = min(32767, max(-32768, round(f * 32768)))
        err = abs(y - fs)
        # coefficient quantization error ~1.2e-4 of w, scaled by |x| and
        # amplified by the 2**-shift amplitude correction
        assert err <= 2 + abs(xs[i]) * 1.5e-4 * (2.0 ** -sh), \
            (wt, log2n, sh, i, y, fs)
        worst = max(worst, err)
        worst_rel = max(worst_rel, err / (1 + abs(fs)))
report['checks'].append({'kind': 'window_path_error',
                         'max_abs_lsb': worst, 'max_relative': worst_rel})

# --- custom uploaded table reproduces internal window exactly --------------
for wt, log2n in [(1, 4), (2, 7), (3, 9)]:
    t = R.gen_window_table(log2n, wt)
    xs = [rng.randrange(-32768, 32768) for _ in range((1 << log2n) + 5)]
    assert (R.window_stream(xs, log2n, wt) ==
            R.window_stream(xs, log2n, 4, table=t))
report['checks'].append({'kind': 'custom_table_equivalence'})

# --- bin-centered DFT through window -> mag_squared -> peak_search ---------
N = 64
BIN = 5
AMP = 0.5
xs = [round(AMP * 32768 * math.cos(2 * math.pi * BIN * n / N))
      for n in range(N)]
for wt in (0, 1, 2, 3):
    ys = [y for y, _ in R.window_stream(xs, 6, wt)]
    # quantized integer DFT scaled into signed16 bins
    scale = 1 / 32
    bins = []
    for k in range(N):
        acc = sum(ys[n] * cmath.exp(-2j * math.pi * k * n / N)
                  for n in range(N))
        bins.append((round(acc.real * scale), round(acc.imag * scale)))
    powers = [R.mag_squared(i, q)[0] for i, q in bins]
    idx, mag, met = R.peak_records(powers, 6)[0]
    assert idx == BIN, (wt, idx)          # bin 5 == bin N-5 tie: earliest wins
    cg = R.coherent_gain(R.gen_window_table(6, wt))
    expect = (AMP * 32768 * cg * N * scale / 2) ** 2
    assert abs(mag - expect) / expect < 0.02, (wt, mag, expect)
report['checks'].append({'kind': 'dft_bin_peak', 'bin': BIN,
                         'note': 'real tone -> symmetric bins, earliest index'})

# --- mag_squared ------------------------------------------------------------
for i, q, sh in [(-32768, -32768, 0), (32767, 32767, 0), (-32768, 32767, 3),
                 (0, 0, 15), (1, 0, 1), (3, 0, 1), (100, -200, 7)]:
    p, clip = R.mag_squared(i, q, sh)
    v = R.rne(i * i + q * q, 1 << sh)
    assert p == v and not clip
assert R.mag_squared(-32768, -32768)[0] == 0x80000000
assert R.mag_squared(1, 0, 1)[0] == 0   # 0.5 ties to even -> 0
assert R.mag_squared(3, 0, 1)[0] == 4   # 9/2 = 4.5 ties to even -> 4
assert R.mag_squared(5, 0, 1)[0] == 12  # 25/2 = 12.5 ties to even -> 12
report['checks'].append({'kind': 'mag_squared'})

# --- block_accum ------------------------------------------------------------
# crafted rounding ties for N=16
assert R.accum_records([8] + [0] * 15, 4)[0][:2] == (8, 0)      # 0.5 -> 0
assert R.accum_records([24] + [0] * 15, 4)[0][:2] == (24, 2)    # 1.5 -> 2
assert R.accum_records([-8] + [0] * 15, 4)[0][:2] == (-8, 0)    # -0.5 -> 0
assert R.accum_records([-24] + [0] * 15, 4)[0][:2] == (-24, -2)  # -1.5 -> -2
assert R.accum_records([40] + [0] * 15, 4)[0][:2] == (40, 2)    # 2.5 -> 2
assert R.accum_records([-40] + [0] * 15, 4)[0][:2] == (-40, -2)  # -2.5 -> -2
assert R.accum_records([-32768] * 16, 4)[0][0] == -524288       # no sum sat
xs = [rng.randrange(-32768, 32768) for _ in range(5000)]
recs = R.accum_records(xs, 12)
assert len(recs) == 1 and recs[0][0] == sum(xs[:4096])
xs = [rng.randrange(-32768, 32768) for _ in range(100)]
assert len(R.accum_records(xs, 6)) == 1   # tail of 36 dropped
report['checks'].append({'kind': 'block_accum'})

# --- peak_search ------------------------------------------------------------
v = [0] * 16
v[2] = v[7] = 100
assert R.peak_records(v, 4)[0] == (2, 100, 1)          # earliest tie
assert R.peak_records(v, 4, 1, 100)[0][2] == 1         # >= threshold met
assert R.peak_records(v, 4, 1, 101)[0][2] == 0         # below threshold
assert R.peak_records([0] * 16, 4)[0][:2] == (0, 0)
v = [rng.randrange(0, 1 << 32) for _ in range(4096)]
idx, mag, _ = R.peak_records(v, 12)[0]
assert mag == max(v) and v[idx] == mag and idx == v.index(mag)
report['checks'].append({'kind': 'peak_search'})

# --- illegal configurations rejected by the model contract ------------------
for bad in [(3, 1, 0), (13, 1, 0), (4, 5, 0), (4, 7, 0), (4, 1, -9), (4, 1, 16)]:
    assert not R.valid_window_cfg(*bad)
assert not R.valid_mag_cfg(16) and not R.valid_accum_cfg(14)
assert not R.valid_peak_cfg(4, 2)
report['checks'].append({'kind': 'illegal_config'})

(OUT / 'summary.json').write_text(json.dumps(report, indent=2))
print(OUT)
print(json.dumps(report, indent=2))

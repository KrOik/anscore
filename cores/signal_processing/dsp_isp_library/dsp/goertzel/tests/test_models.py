import sys, json, random, math
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (Config, rne, rne_real, coefficient, coefficient_frequency,
                       window_rectangular, window_hann, window_hamming, window_custom,
                       float_goertzel, direct_dft_power, bitexact_block,
                       state_bound, dft_agreement_bound, U80_MAX)
rng = random.Random(0x60E7)
cases = []
worst_abs = 0.0; worst_rel = 0.0

def check(samples, cfg, label):
    """bit-exact Goertzel vs direct DFT on identical quantized windowed samples."""
    global worst_abs, worst_rel
    wx = [rne(x * w, 32768) for x, w in zip(samples, cfg.window)]
    got = bitexact_block(samples, cfg)
    assert len(got) == len(cfg.bins)
    for b, (res, c) in enumerate(zip(got, cfg.bins)):
        f = coefficient_frequency(c)
        pd = direct_dft_power(wx, f)
        err = abs(res['power'] - pd)
        bound = dft_agreement_bound(cfg.n)
        assert err <= bound, (label, b, res['power'], pd, err, bound)
        worst_abs = max(worst_abs, err)
        # Relative agreement is asserted only where the bin carries real power
        # (>0.1% of the fully coherent amplitude); null bins can cancel to an
        # exact integer zero, which the absolute bound still covers.
        if pd > (0.01 * sum(abs(w) for w in wx)) ** 2:
            rel = err / pd
            worst_rel = max(worst_rel, rel)
            assert rel < 1e-3, (label, b, rel)
        assert res['bin'] == b and res['last'] == int(b == len(cfg.bins) - 1)
        assert res['detect'] == int(res['power'] >= cfg.thresholds[b])
        cases.append({'case': label, 'bin': b, 'power': res['power'],
                      'dft': pd, 'abs_error': err, 'bound': bound})

# Windowed tones: exact bins, off bins, DC, Nyquist, noninteger frequency.
for n, freqs, wname in [
    (16, [0.0, 0.125, 0.5], 'rect'), (32, [3 / 32, 7.5 / 32], 'hann'),
    (64, [0.0, 9 / 64, 0.497, 0.25], 'hamming'), (256, [0.375, 0.3735], 'rect'),
    (7, [0.2], 'rect'), (1, [0.0], 'rect'), (2, [0.5, 0.0], 'hann')]:
    win = {'rect': window_rectangular, 'hann': window_hann, 'hamming': window_hamming}[wname](n)
    coeffs = tuple(coefficient(f) for f in freqs)
    cfg = Config(n, coeffs, win, (0,) * len(coeffs))
    for amp, fsrc, tag in [(12000, freqs[0], 'on_tone'), (12000, (freqs[-1] + 0.5 / n) % 0.5, 'off_tone'),
                           (32767, 0.0, 'fullscale_dc'), (0, 0.0, 'silence'),
                           (30000, 0.313, 'near_fullscale')]:
        if tag == 'silence':
            xs = [0] * n
        elif tag == 'fullscale_dc':
            xs = [32767] * n
        else:
            xs = [round(amp * math.sin(2 * math.pi * fsrc * k + .3)) for k in range(n)]
        check(xs, cfg, f'n{n}_{wname}_{tag}')
    xs = [rng.randrange(-32768, 32768) for _ in range(n)]
    check(xs, cfg, f'n{n}_{wname}_noise')
    xs = [32767 if k % 2 == 0 else -32768 for k in range(n)]
    check(xs, cfg, f'n{n}_{wname}_nyquist_extreme')

# Custom asymmetric window and multi-bin detection with distinct thresholds.
n = 48
win = window_custom([32768 - k * 512 for k in range(n)])
coeffs = tuple(coefficient(f) for f in (0.0625, 0.25, 0.03125, 0.5))
xs = [round(9000 * math.sin(2 * math.pi * 0.25 * k) + 3000 * math.sin(2 * math.pi * 0.0625 * k)) for k in range(n)]
pre = bitexact_block(xs, Config(n, coeffs, win, (0,) * 4))
thr = tuple(max(0, p['power'] - (1 << 20)) for p in pre)
res = bitexact_block(xs, Config(n, coeffs, win, thr))
assert all(r['detect'] == 1 for r in res)
res = bitexact_block(xs, Config(n, coeffs, win, tuple(p['power'] + 1 for p in pre)))
assert all(r['detect'] == 0 for r in res)
check(xs, Config(n, coeffs, win, (0,) * 4), 'custom_window_4bin')

# Float model (unquantized coefficient) is the algorithm-level reference and
# must match the direct DFT almost exactly on the same windowed samples.
for n, f in [(16, 0.125), (64, 0.3735), (256, 0.5)]:
    xs = [10000.0 * math.sin(2 * math.pi * f * k) for k in range(n)]
    pf = float_goertzel(xs, f)
    pd = direct_dft_power(xs, f)
    assert abs(pf - pd) <= max(1e-4 * pd, 1e-3), (n, f, pf, pd)

# Host coefficient quantization and effective frequency.
assert coefficient(0.0) == 131072 and coefficient(0.5) == -131072
assert abs(coefficient_frequency(coefficient(0.3)) - 0.3) < 2e-4

# Negative-half rounding matches the RTL round functions (sign symmetric RNE).
assert rne(-3 * 65536 - 32768) == -4 and rne(-2 * 65536 - 32768) == -2
assert rne(3 * 65536 + 32768) == 4 and rne(2 * 65536 + 32768) == 2
assert rne(5 * 32768 + 16384, 32768) == 6 and rne(-5 * 32768 - 16384, 32768) == -6
assert rne(4 * 32768 + 16384, 32768) == 4 and rne(-4 * 32768 - 16384, 32768) == -4

# Illegal configurations are rejected by the model contract.
for kw in [dict(n=0), dict(n=257), dict(bins=()), dict(bins=(131072,) * 5),
           dict(bins=(131073,)), dict(bins=(-131073,)), dict(n=4, window=(32768,)),
           dict(n=2, window=(32768, 32769)), dict(thresholds=(0, 0)),
           dict(thresholds=(U80_MAX + 1,))]:
    try:
        Config(**kw)
    except (ValueError, TypeError):
        pass
    else:
        raise AssertionError(('illegal accepted', kw))

print(json.dumps({'status': 'PASS', 'cases': len(cases),
                  'worst_abs_error': worst_abs, 'worst_relative_error': worst_rel,
                  'bound_formula': '8*state_bound*delta + 2*delta^2 + 0.5*state_bound, delta=n(n+1)/4'},
                 indent=2))

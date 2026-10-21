import sys, json, random, math, cmath
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (Config, MAX_TAPS, DW, ACCW, POSW, POS_MAX, SMIN, SMAX,
                       effective_taps, frame_positions, frame_results,
                       float_correlate, fft, ifft, fft_convolve, acc_bound,
                       pack_taps, pack_sample, pack_acc)
rng = random.Random(0xC0E1)
cases = 0
worst_fft_err = 0.0
OUT = Path(__file__).resolve().parents[1] / 'evidence'
OUT.mkdir(exist_ok=True)

def rcfg(ntaps, cplx=0, dir=0, conj=0, tail=0, taps=None):
    if taps is None:
        taps = [(rng.randrange(SMIN, SMAX + 1),
                 rng.randrange(SMIN, SMAX + 1)) for _ in range(ntaps)]
    taps = list(taps) + [(0, 0)] * (MAX_TAPS - len(taps))
    return Config(ntaps, cplx, dir, conj, tail, tuple(taps))

def rxs(n, cplx):
    return [(rng.randrange(SMIN, SMAX + 1),
             rng.randrange(SMIN, SMAX + 1) if cplx else 0)
            for _ in range(n)]

def check_frame(xs, cfg, label):
    """bit-exact frame vs float direct sum vs independent FFT convolution."""
    global cases, worst_fft_err
    outs, peak = frame_results(xs, cfg)
    fo = float_correlate([complex(r, i) for r, i in xs], cfg)
    # The datapath is exact integer arithmetic; every float product and sum
    # below 2^53 is exact, so the float reference must reproduce the integers.
    assert set(fo) == {o['pos'] for o in outs}
    for o in outs:
        f = fo[o['pos']]
        assert abs(f.real - o['re']) < 0.5 and abs(f.imag - o['im']) < 0.5, \
            (label, o, f)
        assert abs(o['re']) <= acc_bound(cfg) and abs(o['im']) <= acc_bound(cfg)
    # Independent FFT convolution of x with the effective taps w[k]:
    # y[pos] = sum_k x[pos-k]*w[k] is exactly linear convolution.
    w = [complex(r, i) for r, i in effective_taps(cfg)]
    conv = fft_convolve([complex(r, i) for r, i in xs], w)
    for o in outs:
        e = abs(conv[o['pos']] - complex(o['re'], o['im']))
        worst_fft_err = max(worst_fft_err, e)
        assert e < 1e-3 * max(1.0, abs(o['re']), abs(o['im'])) or e < 1e-6 * \
            (len(xs) * cfg.ntaps * 32768.0 ** 2), (label, o, conv[o['pos']])
    # Peak contract: earliest maximum of |re|+|im|, error flag when empty.
    if outs:
        mg = [abs(o['re']) + abs(o['im']) for o in outs]
        first_max = next(i for i, v in enumerate(mg) if v == max(mg))
        b = outs[first_max]
        assert peak['pos'] == b['pos'] and peak['error'] == 0
        assert peak['re'] == b['re'] and peak['im'] == b['im']
        assert peak['mag'] == mg[first_max]
    else:
        assert peak['error'] == 1 and peak['pos'] == POS_MAX
    cases += 1
    return outs, peak

# Reset default: real ntaps=1 tap=+32767 VALID -> y = 32767*x at every position.
d = Config()
outs, peak = frame_results([(v, 0) for v in (0, 1, -1, 1000, -32768, 32767)], d)
assert [o['re'] for o in outs] == [32767 * v for v in (0, 1, -1, 1000, -32768, 32767)]
assert [o['pos'] for o in outs] == list(range(6))
assert peak['mag'] == 32767 * 32768 and peak['pos'] == 4  # earliest |-32768*32767|

# Direction semantics: both directions report the trailing-edge lag p+M-1;
# dir=0 (correlation order) detects the taps in upload order, dir=1
# (convolution order) detects the reversed tap sequence.
M, N, p = 5, 24, 9
taps = [(rng.randrange(-8000, 8001), 0) for _ in range(M)]
xs = [(rng.randrange(-100, 101), 0) for _ in range(N)]
for i, t in enumerate(taps):
    xs[p + i] = t
outs, peak = frame_results(xs, rcfg(M, dir=0, tail=1, taps=taps))
assert peak['pos'] == p + M - 1, peak
check_frame(xs, rcfg(M, dir=0, tail=1, taps=taps), 'embed_dir0')
xr = [(rng.randrange(-100, 101), 0) for _ in range(N)]
for i in range(M):
    xr[p + i] = taps[M - 1 - i]
outs, peak = frame_results(xr, rcfg(M, dir=1, tail=1, taps=taps))
assert peak['pos'] == p + M - 1, peak
check_frame(xr, rcfg(M, dir=1, tail=1, taps=taps), 'embed_dir1')

# Complex matched filter: conj template recovers embedded complex template.
Mc, Nc, pc = 6, 20, 4
tc = [(rng.randrange(-4000, 4001), rng.randrange(-4000, 4001)) for _ in range(Mc)]
xc = [(rng.randrange(-100, 101), rng.randrange(-100, 101)) for _ in range(Nc)]
for i, t in enumerate(tc):
    xc[pc + i] = t
cfg = rcfg(Mc, cplx=1, conj=1, dir=0, tail=1, taps=tc)
outs, peak = frame_results(xc, cfg)
assert peak['pos'] == pc + Mc - 1
energy = sum(r * r + i * i for r, i in tc)
assert outs[pc + Mc - 1]['re'] == energy and outs[pc + Mc - 1]['im'] == 0
check_frame(xc, cfg, 'cplx_conj_embed')
# Same frame without conj: im component of the peak position need not vanish.
check_frame(xc, rcfg(Mc, cplx=1, conj=0, dir=0, tail=1, taps=tc), 'cplx_noconj')
check_frame(xc, rcfg(Mc, cplx=1, conj=1, dir=1, tail=1, taps=tc), 'cplx_conv')

# VALID mode: positions M-1..N-1 only; N<M emits nothing and flags peak error.
cfgv = rcfg(4, tail=0)
outs, peak = frame_results(rxs(3, 0), cfgv)
assert outs == [] and peak['error'] == 1 and peak['pos'] == POS_MAX
outs, peak = frame_results(rxs(4, 0), cfgv)
assert len(outs) == 1 and outs[0]['pos'] == 3 and outs[0]['last'] == 1
outs, peak = frame_results(rxs(9, 0), cfgv)
assert [o['pos'] for o in outs] == list(range(3, 9))
assert outs[0]['user'] == 1 and outs[-1]['last'] == 1

# FULL mode: N+M-1 outputs, positions 0..N+M-2, zero-padded partials.
cfgf = rcfg(4, tail=1, taps=[(1, 0), (2, 0), (4, 0), (8, 0)])
xs = [(1, 0), (0, 0), (0, 0)]
outs, peak = frame_results(xs, cfgf)
assert [o['pos'] for o in outs] == list(range(6))
assert [o['re'] for o in outs] == [8, 4, 2, 1, 0, 0]  # dir0: tap order reversed

# Peak ties keep the earliest position (|re|+|im| proxy, strict greater-than).
cfgt = rcfg(2, dir=1, tail=1, taps=[(1, 0), (0, 0)])
outs, peak = frame_results([(5, 0), (5, 0), (-4, 0)], cfgt)
assert [o['re'] for o in outs] == [5, 5, -4, 0]
assert peak['pos'] == 0 and peak['mag'] == 5

# Sweeps across ntaps/mode/direction/tail including extremes and long frames.
for ntaps in (1, 2, 4, 7, 16, 33, MAX_TAPS):
    for tail in (0, 1):
        cfg = rcfg(ntaps, tail=tail)
        for n in (ntaps, ntaps + 3, 40):
            check_frame(rxs(n, 0), cfg, f'real_m{ntaps}_t{tail}_n{n}')
for ntaps in (2, 5, 16, MAX_TAPS):
    for dir_ in (0, 1):
        for conj in (0, 1):
            cfg = rcfg(ntaps, cplx=1, dir=dir_, conj=conj, tail=1)
            check_frame(rxs(ntaps + 11, 1), cfg,
                        f'cplx_m{ntaps}_d{dir_}_c{conj}')

# Saturating/extreme data stays inside the documented accumulator bound.
cfgx = rcfg(MAX_TAPS, cplx=1, tail=1,
            taps=[(SMAX, SMAX)] * MAX_TAPS)
xs = [(SMAX, SMAX)] * 8 + [(SMIN, SMIN)] * 8
check_frame(xs, cfgx, 'extreme_complex')

# Illegal configurations are rejected by the model contract.
pad = [(0, 0)] * MAX_TAPS
for kw in [dict(ntaps=0), dict(ntaps=MAX_TAPS + 1), dict(tail=2),
           dict(conj=1), dict(cplx=1, conj=1, taps=tuple([(32768, 0)] * MAX_TAPS)),
           dict(ntaps=2, taps=tuple([(0, 0)] * 3)),
           dict(ntaps=2, taps=tuple([(70000, 0)] + pad[1:]))]:
    try:
        Config(**kw)
    except (ValueError, TypeError):
        pass
    else:
        raise AssertionError(('illegal accepted', kw))

# Pack helpers: round-trip the 2048-bit template word and 96-bit outputs.
cfg = rcfg(3, taps=[(1, -2), (300, 400), (-32768, 32767)])
v = pack_taps(cfg.taps)
for i, (re, im) in enumerate(cfg.taps):
    assert ((v >> (32 * i)) & 0xFFFF) == re & 0xFFFF
    assert ((v >> (32 * i + 16)) & 0xFFFF) == im & 0xFFFF
assert pack_sample(-1, 32767) == 0x7FFFFFFF
assert pack_acc(-1, -2) == (1 << 96) - (1 << 48) - 1

report = {'status': 'PASS', 'cases': cases,
          'worst_fft_convolution_error': worst_fft_err,
          'scope': 'algorithm models only; integer datapath is exact, '
                   'float and independent FFT convolution are cross-checks'}
(OUT / 'model_validation.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

"""Model validation for DSP-10: float vs bit-exact, structural properties,
measured spectrum targets, alias/image suppression with tone vectors, and
illegal-configuration rejection. Pure stdlib; prints a JSON summary and
writes evidence/model_validation.json next to the run.
"""
import sys, json, random, math, cmath, hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
import reference as ref

rng = random.Random(0xDA10)
report = {'halfband': [], 'ciccomp': [], 'tones': []}
worst_err = 0


def rne_q(v):
    return ref.sat16(ref.rne(v))


# ---- halfband structure and float-vs-exact over all supported lengths
for taps in range(3, ref.HB_MAX_TAPS + 1, 2):
    uc, h, hq = ref.design_halfband(taps)
    c = (taps - 1) // 2
    # structural: center exactly 0.5, zeros exact, symmetry exact
    assert hq[c] == 16384
    for n in range(taps):
        if n != c and (n - c) % 2 == 0:
            assert hq[n] == 0, (taps, n)
        assert hq[n] == hq[taps - 1 - n]
    assert sum(hq) == 32768
    xs = [rng.randrange(-20000, 20001) for _ in range(64)]
    hq_f = [c / 32768 for c in hq]
    d_i = ref.decim_int(xs, taps, uc)
    d_f = ref.decim_float(xs, taps, hq_f)
    e = max(abs(y - f * 32768) for (y, _), f in zip(d_i, d_f))
    # quantized-float vs bit-exact isolates pure RNE/saturation arithmetic
    assert e <= 1.0, (taps, e)
    i_i = ref.interp_int(xs, taps, uc)
    i_f = ref.interp_float(xs, taps, hq_f)
    e2 = max(abs(y - f * 32768) for (y, _), f in zip(i_i, i_f))
    assert e2 <= 1.0, (taps, e2)
    worst_err = max(worst_err, e, e2)
    # independent second realization: zero-stuff then direct convolution
    up = [0] * (2 * len(xs) - 1)
    for k, x in enumerate(xs):
        up[2 * k] = x
    full = [0] * (len(up) + taps - 1)
    for i, x in enumerate(up):
        for k, cf in enumerate(hq):
            full[i + k] += x * cf
    expect = [(ref.sat16(ref.rne(v, 14)),
               int(not -32768 <= ref.rne(v, 14) <= 32767))
              for v in full]
    assert i_i == expect[:2 * len(xs) + taps - 2], taps
    # decimator must equal the even positions of the direct convolution
    xfull = [0] * (len(xs) + taps - 1)
    for i, x in enumerate(xs):
        for k, cf in enumerate(hq):
            xfull[i + k] += x * cf
    dconv = [xfull[2 * m] for m in range(len(d_i))]
    assert [v for v, _ in d_i] == [ref.sat16(ref.rne(v)) for v in dconv], taps
    m = ref.halfband_metrics(taps, uc, 0.15, 0.35)
    report['halfband'].append(m)

# measured targets for the reference T=31 table (see SPEC.md)
uc31, _, hq31 = ref.design_halfband(31)
m31 = ref.halfband_metrics(31, uc31, 0.15, 0.35)
assert m31['passband_max_abs_db'] <= 0.01, m31
assert m31['stopband_attenuation_db'] >= 70.0, m31
assert abs(m31['dc_gain'] - 1.0) < 1e-9
assert m31['nyquist_gain'] < 1e-10

# ---- decimation alias and interpolation image, tone probes
def tone_gain(ys, f, amp, skip=200):
    seg = ys[skip:len(ys) - skip]
    return 2 * abs(sum(y * cmath.exp(-2j * math.pi * f * i)
                       for i, (y, _) in enumerate(seg))) / len(seg) / amp

# decim: stopband tone at 0.42 aliases to 0.16 at output rate, ~-80dB down
n = 2048
xs = [round(12000 * math.sin(2 * math.pi * 0.42 * i)) for i in range(n)]
ys = ref.decim_int(xs, 31, uc31, flush=False)
g = tone_gain(ys, 0.16, 12000)
assert g < 1e-3, g
report['tones'].append({'kind': 'decim_alias', 'f_in': 0.42,
                        'f_out': 0.16, 'gain': g})
# decim passband tone 0.1 -> output 0.2 at ~unity
xs = [round(12000 * math.sin(2 * math.pi * 0.1 * i)) for i in range(n)]
ys = ref.decim_int(xs, 31, uc31, flush=False)
g = tone_gain(ys, 0.2, 12000)
assert abs(g - 1) < 0.02, g
report['tones'].append({'kind': 'decim_pass', 'f_in': 0.1,
                        'f_out': 0.2, 'gain': g})
# interp: input f=0.1 -> fundamental at 0.05, image at 0.45 (output rate)
xs = [round(12000 * math.sin(2 * math.pi * 0.1 * i)) for i in range(n)]
ys = ref.interp_int(xs, 31, uc31, flush=False)
gi = tone_gain(ys, 0.45, 12000)
gp = tone_gain(ys, 0.05, 12000)
assert gi < 1e-3 and abs(gp - 1) < 0.02, (gi, gp)
report['tones'].append({'kind': 'interp_image', 'f_image': 0.45,
                        'gain': gi})
report['tones'].append({'kind': 'interp_pass', 'f': 0.05, 'gain': gp})

# ---- CIC compensation: LS inverse-droop design, measured composite
for order, rate, taps, fp, fstop, crmax, amin in [
        (4, 8, 31, 0.20, 0.35, 0.02, 60.0),
        (4, 8, 15, 0.15, 0.40, 0.03, 55.0),
        (3, 8, 15, 0.20, 0.35, 0.30, 34.0),
        (2, 16, 15, 0.15, 0.40, 0.03, 55.0)]:
    uc, g, hq = ref.design_ciccomp(order, rate, taps, fp, fstop)
    m = ref.ciccomp_metrics(order, rate, taps, uc, fp, fstop)
    assert m['corrected_max_abs_db'] <= crmax, m
    assert m['stopband_attenuation_db'] >= amin, m
    assert abs(m['dc_gain'] - 1.0) < 1e-9
    report['ciccomp'].append({**m, 'fstop': fstop})
    xs = [rng.randrange(-12000, 12001) for _ in range(64)]
    ci = ref.comp_int(xs, taps, uc)
    cf = ref.comp_float(xs, taps,
                        [x / 32768 for x in hq])
    e = max(abs(y - f * 32768) for (y, _), f in zip(ci, cf))
    assert e < 0.5 * len(uc) + 1
    # time-domain droop correction: discrete integrator/decimate/comb CIC
    # feeding the compensation model; a passband tone ends near unity
    def cic_decimate(stream, o, r):
        integ = [0] * o
        combs = [0] * o
        res = []
        for idx, x in enumerate(stream):
            v = x
            for st in range(o):
                integ[st] += v
                v = integ[st]
            if (idx + 1) % r == 0:
                for st in range(o):
                    v, combs[st] = v - combs[st], v
                res.append(v)
        return res
    fin = 0.9 * fp / rate                       # input-rate tone
    tone = [round(9000 * math.sin(2 * math.pi * fin * i))
            for i in range(240 * rate)]
    cic_out = cic_decimate(tone, order, rate)
    # a real chain normalizes the CIC DC gain R^order before signed16;
    # all test rates are powers of two so an exact shift suffices
    shift = order * int(round(math.log2(rate)))
    assert 1 << shift == rate ** order
    scaled = [ref.rne(v, shift) for v in cic_out]
    comp_out = ref.comp_int(scaled, taps, uc, flush=False)
    probe = comp_out[60:len(comp_out) - 60]
    gain = 2 * abs(sum(y * cmath.exp(-2j * math.pi * 0.9 * fp * i)
                       for i, (y, _) in enumerate(probe))) / len(probe)
    assert abs(gain / 9000 - 1.0) < 0.05, (order, rate, taps, gain)

# ---- illegal configs rejected
for bad in (2, 4, 0, -7):
    try:
        ref.design_halfband(bad)
    except ValueError:
        pass
    else:
        raise AssertionError(('halfband', bad))
for bad in (39, 41):
    try:
        ref.design_halfband(bad)
    except ValueError:
        pass
    else:
        raise AssertionError(('halfband', bad))
for bad in (2, 33, 0):
    try:
        ref.design_ciccomp(4, 8, bad, 0.2)
    except ValueError:
        pass
    else:
        raise AssertionError(('ciccomp', bad))

report['status'] = 'PASS'
report['max_float_error_lsb'] = worst_err
OUT = Path(__file__).resolve().parents[1] / 'evidence'
OUT.mkdir(exist_ok=True)
stamp = 'model_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f')
d = OUT / stamp
d.mkdir()
(d / 'summary.json').write_text(json.dumps(report, indent=2))
(d / 'reference_sha256.json').write_text(json.dumps(
    {'reference.py': hashlib.sha256(
        (Path(__file__).resolve().parents[1] / 'models' / 'reference.py')
        .read_bytes()).hexdigest()}, indent=2))
print(json.dumps(report, indent=2))
print(d)

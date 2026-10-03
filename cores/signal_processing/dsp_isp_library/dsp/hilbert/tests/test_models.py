"""Model qualification: FIR spectrum, analytic purity, envelope/phase/freq
accuracy of the bit-exact model vs float reference. Pure stdlib."""
import sys, json, math, cmath, random
from pathlib import Path
BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE / 'models'))
import reference as ref

rng = random.Random(0x4112)
report = {'status': 'PASS'}

# ------------------------------------------------------------ FIR spectrum
m = ref.spectrum_metrics(list(ref.DEFAULT_COEFFS))
assert m['passband_max_abs_db'] < 0.01, m
report['spectrum'] = m

# ------------------------------------------------- single-tone steady state
# For A*cos(2*pi*f*n): z ~ A*exp(j*2*pi*f*(n-C)); envelope ~ A,
# phase slope ~ f cyc/sample, instantaneous freq ~ f.
tones = []
for f in (0.05, 0.08, 0.125, 0.2, 0.25, 0.3, 0.375, 0.44):
    A = 12000
    n = 4096
    xs = [round(A * math.cos(2 * math.pi * f * k)) for k in range(n)]
    model = ref.HilbertModel()
    outs = [model.sample(x) for x in xs]
    s0, s1 = 512, n - 512
    seg = outs[s0:s1]
    env_err = max(abs(o['env'] - A) for o in seg) / A
    # phase slope via end-point difference of unwrapped phase
    ph = [o['phase'] for o in outs]
    uw = [ph[0]]
    for k in range(1, len(ph)):
        d = ref.wrap16(ph[k] - ph[k - 1])
        uw.append(uw[-1] + d)
    slope = (uw[s1 - 1] - uw[s0]) / (s1 - 1 - s0) / 65536
    fq_err = max(abs(o['freq'] - f * 65536) for o in seg) / 65536
    iq = [(o['i'], o['q']) for o in seg]
    # quadrature check: Q ~ A*sin
    q_err = max(abs(o['q'] - A * math.sin(2 * math.pi * f * (k + s0 - ref.CENTER)))
                for k, o in enumerate(seg))
    assert env_err < 0.004, (f, env_err)
    assert abs(slope - f) < 3e-5, (f, slope)
    assert fq_err < 1.5e-4, (f, fq_err)
    assert q_err < 80, (f, q_err)
    tones.append({'f': f, 'env_rel_err': env_err, 'phase_slope': slope,
                  'freq_err_cyc': fq_err, 'q_lsb_err': q_err})
report['inband_tones'] = tones

# -------------------------------------------------- out-of-band behaviour
oob = []
for f in (0.005, 0.01, 0.02, 0.03, 0.46, 0.48, 0.49):
    A = 12000
    n = 4096
    xs = [round(A * math.cos(2 * math.pi * f * k)) for k in range(n)]
    model = ref.HilbertModel()
    outs = [model.sample(x) for x in xs]
    seg = outs[512:n - 512]
    g = abs(ref.response(list(ref.DEFAULT_COEFFS), f))
    env_err = max(abs(o['env'] - A * g) for o in seg) / A
    oob.append({'f': f, 'expected_gain': g,
                'env_rel_err_vs_ideal_gain': env_err})
report['out_of_band'] = oob

# --------------------------------------------------- bitexact vs float IQ
model = ref.HilbertModel()
xs = [rng.randrange(-20000, 20001) for _ in range(2048)]
outs = [model.sample(x) for x in xs]
fi, fq = ref.float_iq(xs)
e_i = max(abs(o['i'] - i / 1) for o, i in zip(outs, fi))  # I is exact delay
assert e_i == 0
qe = max(abs(o['q'] - q) for o, q in zip(outs, fq))
report['q_vs_float_max_lsb'] = qe
assert qe < 8, qe  # coeff+output quantization only

# ----------------------------------- env/phase accuracy on synthetic pairs
worst_env = 0.0
worst_env_abs = 0
worst_ph = 0
for _ in range(60000):
    i = rng.randrange(-32768, 32769)
    q = rng.randrange(-32768, 32769)
    e = ref.envelope(i, q)
    mag = math.hypot(i, q)
    worst_env_abs = max(worst_env_abs, abs(e - mag))
    if mag > 2000:
        worst_env = max(worst_env, abs(e - mag) / mag)
    ph = ref.phase(i, q)
    if mag > 32:
        true = math.atan2(q, i) / (2 * math.pi) % 1 * 65536
        d = abs(ph - true)
        worst_ph = max(worst_ph, min(d, 65536 - d))
report['envelope_max_rel_err_mag_gt_2000'] = worst_env
report['envelope_max_abs_err_lsb'] = worst_env_abs
report['phase_max_err_brads_mag_gt_32'] = worst_ph
assert worst_env < 0.001, worst_env
assert worst_ph < 2.0, worst_ph

# ------------------------------------------------------- zero and DC cases
model = ref.HilbertModel()
o = [model.sample(0) for _ in range(200)]
assert all(t['zero'] and t['phase'] == 0 and t['freq'] == 0 and t['env'] == 0
           for t in o)
model = ref.HilbertModel()
o = [model.sample(10000) for _ in range(200)]
assert o[-1]['i'] == 10000 and o[-1]['env'] >= 9990 and abs(o[-1]['freq']) <= 2
report['zero_dc'] = 'verified: zero flag/phase0/freq0; DC env=|x|, freq~0'

# ----------------------------------------------- extremes / saturation clip
model = ref.HilbertModel()
outs = [model.sample(x) for x in [-32768, 32767] * 300]
assert any(t['clip'] for t in outs)
assert all(-32768 <= t['q'] <= 32767 for t in outs)
# unwrap rule: freq stays bounded (wrapped) near the band edge. Inside the
# qualified band the residual negative-frequency image is ~-80 dB so the
# instantaneous frequency is clean; at 0.49 the finite image rejection makes
# freq oscillate -- recorded as documented edge degradation, not an error.
edge = []
for f in (0.45, 0.48, 0.49):
    model = ref.HilbertModel()
    xs = [round(10000 * math.cos(2 * math.pi * f * k)) for k in range(600)]
    outs = [model.sample(x) for x in xs]
    fq = [t['freq'] for t in outs[400:]]
    assert all(-32768 <= v <= 32767 for v in fq)
    edge.append({'f': f, 'freq_mean': sum(fq) / len(fq) / 65536,
                 'freq_spread_brads': max(fq) - min(fq)})
assert edge[0]['freq_spread_brads'] < 8 and abs(edge[0]['freq_mean'] - 0.45) < 1e-3
report['edge_freq'] = edge
report['extremes'] = 'clip flagged on alternating full-scale; freq wrapped'

# ------------------------------------------------------------ config rules
model = ref.HilbertModel()
assert not model.config(0, list(ref.DEFAULT_COEFFS), True)
assert not model.config(17, list(ref.DEFAULT_COEFFS), True)
assert not model.config(4, [0] * 15, True)
assert model.config(8, list(ref.DEFAULT_COEFFS), True)
assert model.active == 8 and model.hist == []
(BASE / 'evidence').mkdir(exist_ok=True)
(BASE / 'evidence/model_validation.json').write_text(
    json.dumps(report, indent=2))
print(json.dumps(report, indent=2))

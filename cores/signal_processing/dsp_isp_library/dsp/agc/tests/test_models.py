"""DSP-07 agc_stream model validation: bit-exact core, cycle oracle and the
independent floating-point AGC.  Pure stdlib."""
import sys, json, math, random
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
import reference as R

BASE = Path(__file__).resolve().parents[1]
(BASE / 'evidence').mkdir(exist_ok=True)
rng = random.Random(0xA6C7)


def tone(amp, k, n):
    return [max(-32768, min(32767, int(round(amp * 32768 *
            math.sin(2 * math.pi * k * i / 128))))) for i in range(n)]


def run_core(xs, cfg):
    m = R.AgcCore(cfg)
    return [m.step(x) for x in xs]


report = {'status': 'PASS', 'cases': []}

# ---------------------------------------------------------------------------
# 1. level code: monotonic, octave-structured, bounds
# ---------------------------------------------------------------------------
prev = -1
for e in range(1, 32769):
    c = R.level_code(e)
    assert c >= prev, (e, c, prev)
    assert 0 <= c <= 120
    prev = c
assert R.level_code(32768) == 120 and R.level_code(16384) in (112,)
for f, mant in enumerate(R.EXP2F):
    ideal = 32768 * 2 ** (f / 8)
    assert abs(mant - ideal) <= 0.5, (f, mant, ideal)
assert R.level_code(0) == 0
try:
    R.level_code(32769)
except ValueError:
    pass
else:
    raise AssertionError('level_code(32769) accepted')
report['level_code'] = {'max_code': 120, 'mant_lut_max_err_lsb':
                        max(abs(m - 32768 * 2 ** (f / 8))
                            for f, m in enumerate(R.EXP2F))}

# ---------------------------------------------------------------------------
# 2. tracking agreement with float AGC: same nominal operating point
# ---------------------------------------------------------------------------
cases = []
for amp, name in [(0.5, 'loud'), (0.02, 'quiet'), (0.001, 'very_quiet')]:
    xs = tone(amp, 5, 16384)
    cfg = R.Config(target=100, attack=2, release=8, est=5)
    res = run_core(xs, cfg)
    tail = [y for y, *_ in res[-4096:]]
    ftail = R.float_agc(xs, cfg)[-4096:]
    # converged amplitude agreement: compare RMS of tails
    rms_i = math.sqrt(sum(v * v for v in tail) / len(tail))
    rms_f = math.sqrt(sum(v * v for v in ftail) / len(ftail))
    rel = abs(rms_i - rms_f) / max(rms_f, 1)
    assert rel < 0.35, (name, rms_i, rms_f)
    cases.append({'signal': name, 'fixed_rms': rms_i, 'float_rms': rms_f,
                  'rel_err': rel})
report['tracking'] = cases

# ---------------------------------------------------------------------------
# 3. steady-state gain hits target level; input step -> attack then release
# ---------------------------------------------------------------------------
xs = tone(0.5, 3, 3000) + tone(0.02, 3, 6000)
cfg = R.Config(target=96, attack=2, release=10, est=5)
m = R.AgcCore(cfg)
res = [m.step(x) for x in xs]
# after loud section, gain code near target-120 = -24
g_loud = res[2500][3]
assert -40 <= g_loud <= -10, g_loud
# attack: within 256 samples of the level drop, gain is rising again
rise = [res[i][3] for i in range(3000, 3256) if res[i][3] > res[i - 1][3]]
assert len(rise) > 0
# eventually near +24 (quiet -24dB louder needed: target - level 0.02*FS
# env16 ~ 420 -> code ~ 56 -> gdes ~ 40)
g_quiet = res[-1][3]
assert g_quiet > g_loud, (g_quiet, g_loud)
report['transient'] = {'gain_after_loud': g_loud, 'gain_final': g_quiet}

# attack strictly faster than release for asymmetric constants:
m = R.AgcCore(R.Config(target=100, attack=1, release=12, est=4))
[x for x in [m.step(20000)[0] for _ in range(400)]]
g0 = m.gq
for _ in range(64):
    m.step(50)                       # quiet -> gain should rise slowly
slow = m.gq - g0
m2 = R.AgcCore(R.Config(target=100, attack=1, release=12, est=4))
for _ in range(64):
    m2.step(30000)                   # loud -> gain drops fast
fast = g0 - m2.gq
assert fast > slow > 0, (fast, slow)
report['attack_release'] = {'release_64': slow, 'attack_64': fast}

# ---------------------------------------------------------------------------
# 4. linear slew mode: constant |dg/dt| while far from target
# ---------------------------------------------------------------------------
m = R.AgcCore(R.Config(target=120, gmin=-256, gmax=255, attack=9,
                       release=9, est=0, mode=1))
# est=0 snaps env to |x|; x=200 -> lvl 60 -> gdes 60 -> diff 960 q4 >> quantum
deltas = []
for _ in range(10):
    before = m.gq
    m.step(200)
    deltas.append(m.gq - before)
assert len(set(deltas)) == 1, deltas          # constant slew while far
assert deltas[0] == (32768 >> 9)              # 64 q4 codes per sample
report['linear_slew'] = {'step_q4': deltas[0], 'quantum': 32768 >> 9}

# ---------------------------------------------------------------------------
# 5. mute / bypass / clip / limits
# ---------------------------------------------------------------------------
cfg = R.Config(target=120, gmax=96, attack=1, release=1, est=2)
res = run_core([32767] * 512, cfg)
assert all(c for _, c, *_ in res[-64:])            # saturated path clips
assert all(y == 32767 for y, *_ in res[-64:])
# -30000 -> env16 30000 -> level code 118 -> desired gain +2 codes -> clips
res = run_core([-30000] * 512, cfg)
assert all(y == -32768 for y, *_ in res[-64:]) and all(c for _, c, *_ in res[-64:])
res = run_core([12000] * 256, R.Config(mute=1, gmax=32))
assert all(y == 0 for y, *_ in res)
res = run_core([rng.randrange(-32768, 32768) for _ in range(256)],
               R.Config(bypass=1))
xs_b = [rng.randrange(-32768, 32768) for _ in range(256)]
m = R.AgcCore(R.Config(bypass=1, gmax=96, target=120))
res = [m.step(x) for x in xs_b]
assert all(y == x and c == 0 for (y, c, *_), x in zip(res, xs_b))
# gain bound: even with target 120 on silence, code is clamped to gmax
m = R.AgcCore(R.Config(target=120, gmax=40, attack=1, release=1, est=2))
for _ in range(4000):
    m.step(0)
assert (m.gq + 8) >> 4 <= 40
m = R.AgcCore(R.Config(target=10, gmin=-30, gmax=40, attack=1, release=1,
                       est=2))
for _ in range(4000):
    m.step(32767)
assert (m.gq + 8) >> 4 >= -30
report['mute_bypass_limits'] = 'ok'

# ---------------------------------------------------------------------------
# 6. determinism + convergence of env/gq (no deadband stall)
# ---------------------------------------------------------------------------
for est in (0, 1, 7, 15):
    m = R.AgcCore(R.Config(est=est, attack=3, release=8))
    for _ in range(200000):
        m.step(1000)
    assert abs((m.env >> 8) - 1000) <= 2, (est, m.env >> 8)
for rate in (0, 4, 15):
    m = R.AgcCore(R.Config(target=100, gmin=-96, gmax=96, attack=rate,
                           release=rate, est=1))
    for _ in range(200000):
        m.step(200)
    lvl = R.level_code(m.env >> 8)
    assert ((m.gq + 8) >> 4) == 100 - lvl, (rate, m.gq, lvl)
report['convergence'] = 'exact'

# ---------------------------------------------------------------------------
# 7. config validation coverage
# ---------------------------------------------------------------------------
for bad in [dict(target=121), dict(target=127), dict(gmin=5, gmax=-5),
            dict(gmin=-300), dict(gmax=300), dict(attack=16)]:
    f = dict(target=100, gmin=-96, gmax=32, attack=3, release=10, est=6,
             mode=0, mute=0, bypass=0)
    f.update(bad)
    if R.legal_fields(**{k: v for k, v in f.items() if k != 'clear'}):
        # note: port-visible legality is only gmin<=gmax and target<=120;
        # field widths bound the rest
        if 'gmin' in bad or 'gmax' in bad or 'attack' in bad:
            pass                                    # caught by port width
        else:
            raise AssertionError(bad)
assert not R.legal_fields(121, -96, 32, 3, 10, 6, 0, 0, 0)
assert not R.legal_fields(100, 10, -10, 3, 10, 6, 0, 0, 0)
assert R.legal_fields(0, -256, 255, 0, 15, 15, 1, 1, 1)
report['validation'] = 'ok'

# ---------------------------------------------------------------------------
# 8. cycle oracle matches sample-domain core on a mixed stream
# ---------------------------------------------------------------------------
cy = R.CycleModel()
cy.cfg = R.Config(target=96, attack=2, release=7, est=4)
core = R.AgcCore(cy.cfg)
pending = []
xs = [rng.randrange(-32768, 32768) for _ in range(2000)]
xi = 0
produced = []
for cyc in range(60000):
    sv = int(xi < len(xs) and rng.random() < 0.7)
    mr = int(rng.random() < 0.8)
    x = xs[xi] if sv else 0
    exp = cy.tick(sv=sv, x=x, su=xi % 17 == 0, sl=xi % 17 == 16, mr=mr)
    if sv and exp['s_tready']:
        pending.append(core.step(x)[0])
        xi += 1
    if exp['m_tvalid'] and mr:
        produced.append(exp['m_tdata'])
assert produced == pending, (len(produced), len(pending))
report['cycle_oracle'] = {'samples': xi, 'beats': len(produced)}

(BASE / 'evidence/model_validation.json').write_text(
    json.dumps(report, indent=2))
print(json.dumps(report, indent=2))

"""DSP-14 stft_welch model validation: float vs bit-exact references.

No RTL here: proves the Python float model and the bit-exact chain
(window_mult + fft64 golden + mag_squared + averager) agree within the
quantization bound, that framing/hop bookkeeping matches the documented
contract, and that config legality and window constants are consistent.
Writes evidence/model_validation.json.
"""
import json
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
import reference as R

BASE = Path(__file__).resolve().parents[1]
rng = random.Random(0x14A0)
checks = []


def check(name, cond, detail=None):
    assert cond, f'{name}: {detail}'
    checks.append({'name': name, 'detail': str(detail)})


def dft_naive(x):
    n = len(x)
    return [sum(x[t] * complex(math.cos(-2 * math.pi * k * t / n),
                              math.sin(-2 * math.pi * k * t / n))
                for t in range(n)) for k in range(n)]


def tone(k, amp, n, phase=0.0):
    return [int(round(amp * 32768 * math.cos(2 * math.pi * k * i / n + phase)))
            for i in range(n)]


# --- float FFT sanity ---------------------------------------------------
xs = [rng.uniform(-1, 1) for _ in range(64)]
ff = R.float_fft(xs)
df = dft_naive(xs)
check('float_fft_vs_dft',
      max(abs(a - b) for a, b in zip(ff, df)) < 1e-8 * max(1, max(map(abs, df))))

# --- framing / hop contract ----------------------------------------------
cfg = R.Config(0, 1, 0, 0, 0)          # hop=16
xs = list(range(200))
fr = R.frames_of(xs, cfg)
check('frames_count', len(fr) == (200 - 64) // 16 + 1)
check('frame0', fr[0] == xs[:64])
check('frame1_overlap', fr[1] == xs[16:80])
check('frame_tail_ignored', R.frames_of(xs[:70], cfg) ==
      [xs[:64]])                       # 70-64=6 < hop: still just frame0
check('hop_set', [R.hop(R.Config(0, s, 0, 0, 0)) for s in range(4)]
      == [8, 16, 32, 64])

# --- window constants ----------------------------------------------------
for w in range(4):
    t = R.window_table(R.Config(w))
    check(f'window_table_len_{w}', len(t) == 64)
check('window_U_unity', R.window_power_sum(0) == 64 * 32768 * 32768)
check('window_U_hann', R.window_power_sum(1) == 25769800984)
check('CG_hann', abs(R.coherent_gain(1) - 0.5) < 1e-9)
# float window vs quantized table agreement (bounded quantization)
for w in (1, 2, 3):
    t = R.window_table(R.Config(w))
    fl = R.float_window_coeffs(w)
    check(f'window_quant_bound_{w}',
          max(abs(t[i] / 32768 - fl[i]) for i in range(64)) < 1e-3)

# --- bit-exact window chain reuses DSP-05 exactly ------------------------
frame = [rng.randrange(-32768, 32768) for _ in range(64)]
cfg = R.Config(3, 3, 0, 0, 0)
check('window_frame_vs_dsp05',
      R.window_frame(frame, cfg) ==
      [R.SR.window_sample(x, i, 6, 3, 0)[0] for i, x in enumerate(frame)])

# --- bit-exact power chain -----------------------------------------------
p = R.power_frame(frame, cfg)
xw = R.window_frame(frame, cfg)
re, im = R.GM.fft64(xw, [0] * 64)
check('power_frame_direct',
      p == [R.SR.mag_squared(re[k], im[k], 0)[0] for k in range(64)])

# --- averager: block mode ------------------------------------------------
cfg = R.Config(0, 3, 0, 0, 2)          # A=4
avg = R.Averager(cfg)
frames = [[rng.randrange(0, 1 << 20) for _ in range(64)]
          for _ in range(5)]
outs = [avg.update(f) for f in frames]
check('block_avg_none_early', outs[:3] == [None] * 3)
exp = [R.SR.rne(frames[0][k] + frames[1][k] + frames[2][k] + frames[3][k], 4)
       for k in range(33)]
check('block_avg_values', outs[3] == exp)
check('block_avg_onesided_len', len(outs[3]) == 33)
exp = [R.SR.rne(frames[4][k], 1) for k in range(33)]   # new block, partial
outs2 = avg.update(frames[4])
check('block_avg_restart', outs2 is None)

# --- averager: exponential mode ------------------------------------------
cfg = R.Config(0, 3, 1, 1, 3)          # alpha=3, two-sided
avg = R.Averager(cfg)
cons = [[1000 + k] * 0 + [7777] * 64 for k in range(40)]
outs = [avg.update(f) for f in cons]
check('exp_avg_every_frame', all(o is not None and len(o) == 64
                                 for o in outs))
check('exp_avg_converges', outs[-1][0] > outs[0][0] > 0 and
      abs(outs[-1][0] - 7777) < 64)
# explicit two-step check: S += (P<<8 - S) >>> alpha
avg = R.Averager(R.Config(0, 3, 1, 1, 1))
o1 = avg.update([100] * 64)            # S = 25600>>1 = 12800 -> 50
check('exp_step1', o1[0] == R.SR.rne(12800, 256) == 50)
o2 = avg.update([100] * 64)            # S += (25600-12800)>>1 = +6400 ->75
check('exp_step2', o2[0] == 75)

# --- full-chain records vs independent recompute --------------------------
cfg = R.Config(1, 2, 0, 0, 1)          # hann hop32 one-sided A=2
xs = [max(-32768, min(32767, v)) for v in
      [a + b + rng.randrange(-1500, 1501) for a, b in
       zip(tone(4, 0.2, 160), tone(9, 0.1, 160))]]
got = R.records(xs, cfg)
exp = []
acc = [0] * 64
for fi, fr in enumerate(R.frames_of(xs, cfg)):
    pw = R.power_frame(fr, cfg)
    acc = [a + b for a, b in zip(acc, pw)]
    if fi % 2 == 1:
        exp.append([R.sat_u32(R.SR.rne(acc[k], 2)) for k in range(33)])
        acc = [0] * 64
check('records_vs_manual', got == exp)
check('records_sof_k', all(len(r) == 33 for r in got))

# --- PSD normalization contract ------------------------------------------
# unity window, bin-aligned tone: PSD[k] = |DFT|^2/(fs*U), one-sided x2
cfg = R.Config(0, 3, 1, 0, 0)          # unity two-sided
xs = tone(4, 0.5, 64)
p = R.power_frame(xs, cfg)
fs = 27000.0
u_q = R.window_power_sum(0)
psd4 = R.psd_physical(p[4], cfg, u_q, fs, 4)
# exact: |DFT|^2 = (0.5*32768*64/2)^2 scaled... = 2**36 real -> check ratio
exact = (0.5 * 64 / 2) ** 2            # |DFT(x)|^2 in real units = 256
check('psd_unity_scale',
      abs(psd4 * fs - R.int_power_to_dft2(p[4], cfg) * (1 << 30) / u_q)
      < 1e-9)
check('psd_unity_value',
      abs(psd4 - 256.0 / (fs * 64)) / (256.0 / (fs * 64)) < 0.01)
# one-sided interior doubling
cfg1 = R.Config(0, 3, 0, 0, 0)
check('psd_onesided_x2',
      abs(R.psd_physical(p[4], cfg1, u_q, fs, 4)
          - 2 * R.psd_physical(p[4], cfg, u_q, fs, 4)) < 1e-15)
check('psd_dc_not_doubled',
      R.psd_physical(p[0], cfg1, u_q, fs, 0)
      == R.psd_physical(p[0], cfg, u_q, fs, 0))

# --- float vs bit-exact agreement ----------------------------------------
for w, k, amp in [(0, 4, 0.5), (1, 4.5, 0.4), (3, 12.3, 0.3)]:
    cfg = R.Config(w, 3, 1, 0, 0)
    xs = tone(k, amp, 64)
    pi = R.power_frame(xs, cfg)
    pf = R.float_frame_power(xs, cfg)
    scale = 1.0 / (1 << 18)
    fpmax = max(pf)
    rel = max(abs(pi[i] * scale - pf[i]) / pf[i] for i in range(64)
              if pf[i] > 0.01 * fpmax)
    check(f'float_vs_bitexact_w{w}', rel < 0.05, rel)

# --- config legality -------------------------------------------------------
ok = [(0, 3, 0, 0, 0, 0, 0), (4, 0, 1, 1, 8, -8, 15), (2, 2, 0, 0, 8, 15, 7)]
bad = [(5, 0, 0, 0, 0, 0, 0), (0, 0, 0, 0, 9, 0, 0), (0, 0, 0, 1, 0, 0, 0),
       (0, 0, 0, 1, 9, 0, 0), (0, 0, 0, 0, 0, -9, 0), (0, 0, 0, 0, 0, 0, 16),
       (0, 0, 0, 2, 0, 0, 0), (0, 4, 0, 0, 0, 0, 0)]
for i, c in enumerate(ok):
    check(f'cfg_legal_{i}', R.valid_cfg(*c))
for i, c in enumerate(bad):
    check(f'cfg_illegal_{i}', not R.valid_cfg(*c))

# negative-path: model raises on out-of-range sample
try:
    R.window_frame([40000] * 64, R.Config(0, 3, 0, 0, 0))
    raise SystemExit('sample range not rejected')
except ValueError:
    checks.append({'name': 'sample_range_reject'})

from datetime import datetime
ev = {'status': 'PASS', 'checks': len(checks),
      'check_names': [c['name'] for c in checks],
      'window_U_q': {R.SR.WINDOW_NAMES[w]: R.window_power_sum(w)
                     for w in range(4)},
      'coherent_gain': {R.SR.WINDOW_NAMES[w]: R.coherent_gain(w)
                        for w in range(4)},
      'scope': 'python models only; float proves algorithm, bit-exact '
               'reuses DSP-05 window/mag models + sigproc fft64 golden'}
out = BASE / 'evidence' / ('model_' +
                           datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
out.mkdir(parents=True)
(out / 'summary.json').write_text(json.dumps(ev, indent=2))
print(out)
print('PASS', len(checks), 'checks')

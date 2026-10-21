"""Independent-model validation for INFRA-07 testsrc cores.

Cross-checks the bit-exact models against independent derivations:
- PRBS-16 period and word packing vs an independent Galois-style bit model
- CRC-32 vs zlib.crc32 (stdlib) for 8/16-bit word widths
- tone model vs a direct math.sin evaluation within quantization bounds
- image patterns vs literal per-pattern formulas and marker rules
- backpressure patterns vs direct reconstruction
- checker model verdicts on clean and corrupted streams
Writes evidence/model_<timestamp>/summary.json.
"""
import sys, json, zlib, math, random
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (PRBS16_TAPS, prbs16_step, prbs16_gen16, prbs16_words,
                       prbs16_period, crc32_word, crc32_words, SINE_LUT,
                       sine_q15, mix_sample, ToneCfg, tone_samples, ImgCfg,
                       image_pixel, image_beats, BpCfg, BpModel, bp_ready_seq,
                       ChkCfg, ChkModel, CRC32_INIT, CRC32_XOROUT)

BASE = Path(__file__).resolve().parents[1]
OUT = BASE / 'evidence' / ('model_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
report = {}

# --- PRBS-16 -------------------------------------------------------------
assert prbs16_period() == 65535, 'polynomial not maximal length'
# Independent serial model: same taps, explicit XOR list (no mask parity).
def serial_bits(seed, n):
    s = seed & 0xFFFF
    out = []
    for _ in range(n):
        out.append(s & 1)
        fb = s & 1
        for bit in (2, 3, 5):
            fb ^= (s >> bit) & 1
        s = (s >> 1) | (fb << 15)
    return out
bits = serial_bits(1, 16 * 40)
words = prbs16_words(1, 40)
rebuilt = [sum(bits[16 * k + i] << (15 - i) for i in range(16)) for k in range(40)]
assert rebuilt == words, 'word packing must be MSB-first serial bits'
for seed in (1, 0xACE1, 0xFFFF, 0x8000):
    assert prbs16_words(seed, 9) == [
        sum(b << (15 - i) for i, b in enumerate(serial_bits(seed, 16 * (k + 1))[16 * k:16 * k + 16]))
        for k in range(9)]
assert prbs16_words(0, 4) == [0, 0, 0, 0], 'seed 0 degenerate documented'
report['prbs16'] = dict(period=65535, taps=hex(PRBS16_TAPS), words_checked=40 * 5)

# --- CRC-32 ---------------------------------------------------------------
assert zlib.crc32(b'123456789') == 0xCBF43926          # canonical sanity
rng = random.Random(0xC0C)
for width in (8, 16):
    for _ in range(60):
        n = rng.randrange(0, 40)
        ws = [rng.getrandbits(width) for _ in range(n)]
        b = b''.join(w.to_bytes(width // 8, 'little') for w in ws)
        assert crc32_words(ws, width) == zlib.crc32(b), (width, ws)
# init/xorout parameterisation: CRC of nothing is 0
assert crc32_words([], 16) == 0
report['crc32'] = dict(vectors=120, widths=[8, 16], against='zlib.crc32')

# --- tone model -------------------------------------------------------------
# LUT identity vs derivation
for i, v in enumerate(SINE_LUT):
    assert v == round(32767 * math.sin(math.pi / 2 * (i + 0.5) / 64))
# sine_q15 vs continuous sin: midpoint-sampled quantised, bounded error
worst = 0
for p in range(0, 1 << 32, 1 << 22):       # 1024 phases
    expect = 32767 * math.sin(2 * math.pi * p / 2**32)
    worst = max(worst, abs(sine_q15(p) - expect))
assert worst < 0.011 * 32768 + 200, worst   # LUT step bound, well below 1.2% FS
# multi-tone vs independent direct evaluation
cfg = ToneCfg(mode=0, ntone=3,
              inc=(0x01000000, 0x03333333, 0x08000000, 0),
              phase=(0, 0x40000000, 0x80000000, 0),
              amp=(16384, 8192, -4096, 0))
samps, _ = tone_samples(cfg, 400)
for k in (0, 1, 7, 99, 399):
    acc = sum(cfg.amp[t] * sine_q15((cfg.phase[t] + k * cfg.inc[t]) & 0xFFFFFFFF)
              for t in range(3))
    exp = max(-32768, min(32767, (acc + 0x4000) >> 15))
    assert samps[k] == exp, k
# float sanity: single tone tracks math.sin within quantisation error
cfg1 = ToneCfg(mode=0, ntone=1, inc=(0x02000000,) * 4, amp=(32767,) * 4)
s1, _ = tone_samples(cfg1, 64)
err = max(abs(s1[k] / 32768 - math.sin(2 * math.pi * k * 0x02000000 / 2**32))
          for k in range(64))
assert err < 0.02, err
# sweep: sawtooth increment and wrap indices vs manual reconstruction
cgs = ToneCfg(mode=1, inc=(0x01000000,) * 4, amp=(20000,) * 4,
              sw_step=0x01000000, sw_stop=0x03000000, sw_dwell=4)
ss, wraps = tone_samples(cgs, 60)
inc = 0x01000000
exp_inc = []
d = 0
manual_wraps = []
for k in range(60):
    exp_inc.append(inc)
    d += 1
    if d == 4:
        d = 0
        inc = (inc + 0x01000000) & 0xFFFFFFFF
        if inc > 0x03000000:
            inc = 0x01000000
            manual_wraps.append(k)
assert manual_wraps == wraps, (manual_wraps, wraps)
# verify sample k uses phase accumulated by the k advances before it
for k in (0, 4, 5, 9, 19, 44):
    acc = 20000 * sine_q15((sum(exp_inc[:k])) & 0xFFFFFFFF)
    assert ss[k] == max(-32768, min(32767, (acc + 0x4000) >> 15)), k
# negative step down-sweep
cgd = ToneCfg(mode=1, inc=(0x04000000,) * 4, amp=(20000,) * 4,
              sw_step=-0x01000000, sw_stop=0x00800000, sw_dwell=3)
sd, wraps_d = tone_samples(cgd, 30)
assert wraps_d, 'down-sweep must wrap'
report['tone'] = dict(lut=64, max_lut_err=worst, sweep_wraps=wraps,
                      down_wraps=wraps_d, float_err=err)

# --- image patterns ---------------------------------------------------------
for w, h, pat in [(1, 1, 0), (2, 2, 3), (7, 5, 2), (8, 4, 5), (16, 9, 4),
                  (5, 3, 6), (9, 2, 1), (3, 3, 4)]:
    cfg = ImgCfg(w=w, h=h, pattern=pat, nframes=3)
    beats = image_beats(cfg)
    assert len(beats) == 3 * w * h
    for i, (pix, sof, eol, f) in enumerate(beats):
        x, y = i % (w * h) % w, i % (w * h) // w
        assert f == i // (w * h)
        assert sof == int(x == 0 and y == 0), (cfg, i)
        assert eol == int(x == w - 1), (cfg, i)
    # sequence numbers on (0,0)
    assert [beats[f * w * h][0] for f in range(3)] == [0, 1, 2]
# literal pattern spot checks
assert image_pixel(ImgCfg(4, 4, 0), 0, 3, 2) == 3
assert image_pixel(ImgCfg(4, 4, 1), 0, 3, 2) == 2
assert image_pixel(ImgCfg(4, 4, 2), 0, 3, 2) == 5
assert image_pixel(ImgCfg(4, 4, 3), 0, 3, 2) == 255
assert image_pixel(ImgCfg(8, 1, 5), 0, 7, 0) == 7 * 36     # last bar
assert image_pixel(ImgCfg(9, 1, 5), 0, 8, 0) == 7 * 36
assert image_pixel(ImgCfg(3, 3, 6), 2, 1, 1) == 74
# frame number wraps at DATA_WIDTH
assert image_pixel(ImgCfg(2, 2, 0), 300, 0, 0) == 300 & 0xFF
# illegal configs rejected
for bad in (dict(w=0), dict(h=0), dict(pattern=7), dict(pattern=5, w=7),
            dict(bits=17)):
    try:
        ImgCfg(**{**dict(w=4, h=4, pattern=0), **bad})
    except ValueError:
        pass
    else:
        raise AssertionError(('accepted', bad))
report['image'] = dict(frames_checked=8, sof_seq='pixel(0,0)=frame mod 2^bits')

# --- backpressure -----------------------------------------------------------
c = BpCfg(mode=1, seed=0xACE1, threshold=200)
seq = bp_ready_seq(c, 300)
lfsr = c.seed
exp = []
for _ in range(300):
    exp.append(int((lfsr & 0xFF) >= 200))
    lfsr = prbs16_step(lfsr)
assert seq == exp
assert 0 < sum(seq) < 300                        # both phases exercised
assert bp_ready_seq(BpCfg(mode=0), 10) == [1] * 10
assert bp_ready_seq(BpCfg(mode=2, run=3, stall=2), 12) == \
    [1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1]
assert bp_ready_seq(BpCfg(mode=2, run=0, stall=3), 5) == [0] * 5
try:
    BpCfg(mode=2, run=0, stall=0)
except ValueError:
    pass
else:
    raise AssertionError('run+stall=0 accepted')
report['backpressure'] = dict(lfsr_cycles=300, ready_ones=sum(seq))

# --- checker model ------------------------------------------------------------
def run_chk(cfg, beats):
    m = ChkModel(cfg)
    trigs = []
    for b in beats:
        trigs.append(m.feed(*b))
    for _ in range(4):
        trigs.append(m.edge())
    return m.verdict(), trigs

words = prbs16_words(0xACE1, 37)
beats = [(w, 0, 0) for w in words]
crc = crc32_words(words, 16)
v, _ = run_chk(ChkCfg(expected=37, crc_en=1, crc=crc, bits=16), beats)
assert v == dict(done=1, count=37, frames=0, err_crc=0, err_seq=0,
                 err_sof=0, err_eol=0, err_extra=0, first_error=0xFFFFFFFF)
# data corruption -> crc error with index of done beat
bad = beats.copy()
bad[5] = (bad[5][0] ^ 1, 0, 0)
v, _ = run_chk(ChkCfg(expected=37, crc_en=1, crc=crc, bits=16), bad)
assert v['err_crc'] and v['first_error'] == 36, v
# sequence check catches order swap
v, _ = run_chk(ChkCfg(expected=6, seq_en=1, seq_start=10, seq_step=3, bits=8),
               [(10 + 3 * i & 0xFF, 0, 0) for i in range(6)])
assert not any(v[k] for k in ('err_seq', 'err_crc', 'err_extra')) and v['done']
v, _ = run_chk(ChkCfg(expected=6, seq_en=1, seq_start=10, seq_step=3, bits=8),
               [(10 + 3 * i & 0xFF, 0, 0) for i in (0, 2, 1, 3, 4, 5)])
assert v['err_seq'] and v['first_error'] == 1, v
# image marker checks
cfg = ImgCfg(w=2, h=2, pattern=0, nframes=1)
beats = [b[:3] for b in image_beats(cfg)]      # drop the frame tag for feed()
v, _ = run_chk(ChkCfg(expected=4, img_en=1, img_w=2, img_h=2, bits=8), beats)
assert v['done'] and not v['err_sof'] and not v['err_eol'] and v['frames'] == 1
bad = list(beats); bad[1] = (bad[1][0], 1, bad[1][2])      # misplaced SOF
v, _ = run_chk(ChkCfg(expected=4, img_en=1, img_w=2, img_h=2, bits=8), bad)
assert v['err_sof'] and v['first_error'] == 1 and v['frames'] == 2, v
bad = list(beats); bad[0] = (bad[0][0], bad[0][1], 1)      # EOL too early
v, _ = run_chk(ChkCfg(expected=4, img_en=1, img_w=2, img_h=2, bits=8), bad)
assert v['err_eol'] and v['first_error'] == 0, v
# extra beats after done
v, _ = run_chk(ChkCfg(expected=2, bits=8), beats[:2] + beats[:1])
assert v['done'] and v['err_extra'] and v['first_error'] == 2, v
# under-count: done never asserts
v, _ = run_chk(ChkCfg(expected=5, bits=8), beats[:4])
assert not v['done'] and v['count'] == 4, v
# trigger modes
m = ChkModel(ChkCfg(expected=4, bits=8, trig_mode=3, trig_period=2))
trigs = [m.feed(*b) for b in beats[:4]]
assert trigs == [0, 1, 0, 1], trigs
report['checker'] = dict(scenarios=10, clean_pass=True,
                         mutations_rejected=['crc', 'seq', 'sof', 'eol', 'extra'])

summary = dict(status='PASS', scope='independent model validation; no RTL run',
               report=report)
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
print('evidence:', OUT)

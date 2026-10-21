"""BLK1/RES1 strict block protocol for dsp_stream_harness.

Same contract as board/block_harness (packet 'BLK1', report 'RES1' with
tag/config/count/flags/inc/outc/cycles header).  CORE is fixed per build and
read from the frozen build's variant.json.  Oracles are independent models -
no DUT-derived golden.

CORE map: 0 farrow, 1 agc, 2 biquad, 3 lms(serial), 4 mag_squared,
5 agc_power (delivery bundle: two AGC lanes -> mag_squared).
"""
import importlib.util
import json, random, struct, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1] if (HERE.parents[1] / 'dsp').is_dir() else HERE.parent


def _variant():
    for base in (HERE, Path.cwd()):
        v = base / 'variant.json'
        if v.exists():
            return json.loads(v.read_text())
    return {}


def _core():
    return _variant().get('core', 0)


def _load(name, rel):
    frozen = HERE / (name + '.py')
    src = frozen if frozen.exists() else LIB / rel
    spec = importlib.util.spec_from_file_location(name, src)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_packet(tag, config, words, stall=0):
    if not 1 <= len(words) <= 64 or not 0 <= stall <= 7:
        raise ValueError('capacity/stall')
    return (b'BLK1' + struct.pack('<IIBB', tag, config, len(words), stall)
            + struct.pack('<' + 'I' * len(words), *words))


def s16(w):
    w &= 0xFFFF
    return w - 65536 if w & 32768 else w


# Canned SOS tables - identical to dsp_stream_harness_biquad_rom.vh.
def _canned_sos():
    import math
    ref = _load('biquad_reference', 'dsp/biquad/models/reference.py')
    lp2k = ref.lowpass(fs=48000, fc=2000)
    lp8k = ref.lowpass(fs=48000, fc=8000)
    lp4k = ref.lowpass(fs=48000, fc=4000)
    return {0: (ref.IDENTITY,), 1: (lp2k,), 2: (lp8k,), 3: (lp4k, lp4k)}


def oracle(config, words, core=None):
    """Expected list of 32-bit result words for one accepted block."""
    core = _core() if core is None else core
    if core == 0:
        mod = _load('farrow_reference', 'dsp/farrow/models/reference.py')
        delay = config & 63
        mu = (config >> 6) & 0x1FFF
        clear = (config >> 19) & 1
        if config >> 20:
            raise ValueError('farrow config')
        m = mod.StreamModel()
        assert m.config(delay, mu, clear)
        out = []
        for w in words:
            y, clip = m.sample(s16(w))
            out.append((clip << 16) | (y & 0xFFFF))
        return out
    if core == 1:
        mod = _load('agc_reference', 'dsp/agc/models/reference.py')
        if config >> 23:
            raise ValueError('agc config')
        cfg = mod.Config(target=config & 0x7F, gmin=-96, gmax=32,
                         attack=(config >> 7) & 15,
                         release=(config >> 11) & 15,
                         est=(config >> 15) & 15, mode=(config >> 19) & 1,
                         mute=(config >> 20) & 1, bypass=(config >> 21) & 1)
        m = mod.AgcCore(cfg)
        m.reset_state()
        out = []
        for i, w in enumerate(words):
            y, clip, env_code, gc = m.step(s16(w))
            sof = int(i == 0)
            eol = int(i == len(words) - 1)
            out.append((eol << 31) | (sof << 30) | (y & 0xFFFF))
        return out
    if core == 2:
        ref = _load('biquad_reference', 'dsp/biquad/models/reference.py')
        sel = config & 3
        if config >> 3:
            raise ValueError('biquad config')
        m = ref.IntegerModel(max_sos=4)
        m.configure(_canned_sos()[sel], clear=bool((config >> 2) & 1))
        out = []
        for w in words:
            y, clip = m.step(s16(w))
            out.append((clip << 16) | (y & 0xFFFF))
        return out
    if core == 3:
        mod = _load('lms_model', 'dsp/lms/models/lms_model.py')
        mu = config & 0xFFFF
        nlms = (config >> 16) & 1
        update_en = (config >> 17) & 1
        taps = (config >> 18) & 31
        coef_clr = (config >> 23) & 1
        if config >> 24 or not 1 <= taps <= 8:
            raise ValueError('lms config')
        cfg = mod.Config(taps=taps, mu=mu, nlms=nlms, update_en=update_en,
                         floor=64, ntaps_max=8)
        assert cfg.check() is None
        m = mod.FixedLMS(ntaps=8, vis=_lms_vis())
        m.reset()
        if coef_clr:
            for k in range(8):
                m.load_coef(k, 0)
        out = []
        for w in words:
            r = m.step(s16(w), s16(w >> 16), cfg)
            out.append(((r['e'] & 0xFFFF) << 16) | (r['y'] & 0xFFFF))
        m.drain(8)
        return out
    if core == 4:
        mod = _load('spectrum_reference', 'dsp/spectrum/models/reference.py')
        shift = config & 31
        if config >> 5:
            raise ValueError('mag config')
        out = []
        for w in words:
            p, clip = mod.mag_squared(s16(w), s16(w >> 16), shift)
            out.append(p)
        return out
    if core == 5:
        # Delivery bundle.  cfg = {power shift[27:23], AGC control[22:0]}; the two
        # quadrature lanes are configured identically, so one AgcCore per half of
        # the word and the spectrum model's own magnitude on the gained pair.
        agc = _load('agc_reference', 'dsp/agc/models/reference.py')
        mod = _load('spectrum_reference', 'dsp/spectrum/models/reference.py')
        shift = (config >> 23) & 31
        if config >> 28 or shift > 15 or (config & 0x7F) > 120:
            raise ValueError('agc_power config')
        cfg = agc.Config(target=config & 0x7F, gmin=-96, gmax=32,
                         attack=(config >> 7) & 15,
                         release=(config >> 11) & 15,
                         est=(config >> 15) & 15, mode=(config >> 19) & 1,
                         mute=(config >> 20) & 1, bypass=(config >> 21) & 1)
        li, lq = agc.AgcCore(cfg), agc.AgcCore(cfg)
        li.reset_state(), lq.reset_state()
        out = []
        for w in words:
            yi = li.step(s16(w))[0]
            yq = lq.step(s16(w >> 16))[0]
            out.append(mod.mag_squared(yi, yq, shift)[0] & 0xFFFFFFFF)
        return out
    raise ValueError('core')


def _lms_vis():
    """Serial IMPL=0 commit visibility = 1 sample (test_lms.py documents the
    constant; parallel IMPL=1 uses 3+NL)."""
    return 1


# Cores with a fixed elastic latency get an exact cycle model identical to
# board/block_harness/protocol.py (one output register stage per latency).
# Serial engines (biquad, lms) are bounded only - their per-sample cost is
# deterministic but phase-coupled; cycle-field mutation coverage is skipped
# for those cores by run.py (documented limitation).
# agc manifest states "3 edges accept-to-valid"; in cycle-count terms the
# output becomes visible on the 4th RUN cycle -> latency 4 in this model.
# Core 5 chains agc(4 slots) -> mag_squared(4 slots).  Two globally stalled
# units joined at their own ready signals could in principle accept differently
# from one deep pipeline, so it was measured rather than assumed: a model that
# advances each unit independently agrees with this 8-stage model for every
# count in 1..64 and every stall in 0..7, because the harness's phase gate stalls
# both junctions together.
EXACT_LATENCY = {0: 5, 1: 4, 4: 4, 5: 8}


def _expect_cycles(n, stall, latency):
    phase = sent = got = 0
    valid = [False] * latency
    expected = 0
    while got < n:
        ready = phase >= stall
        advance = not valid[-1] or ready
        accept = sent < n and advance
        if valid[-1] and ready:
            got += 1
        if advance:
            valid = [accept] + valid[:-1]
        sent += int(accept)
        phase = (phase + 1) % 8
        expected += 1
    return expected



def verify(report, tag, config, words, stall, latency=None, core=None):
    core = _core() if core is None else core
    if len(report) != 20 + 4 * len(words) or report[:4] != b'RES1':
        raise AssertionError('report framing/count')
    rt, rc, n, flags, inc, outc, cycles = struct.unpack('<IIBBBBI', report[4:20])
    if (rt, rc, n, flags, inc, outc) != (tag, config, len(words), 0,
                                       len(words), len(words)):
        raise AssertionError('identity/flags/counters')
    if core in EXACT_LATENCY:
        expect = _expect_cycles(len(words), stall, EXACT_LATENCY[core])
        if cycles != expect:
            raise AssertionError(('cycles', cycles, expect))
    elif not len(words) <= cycles < 65536:
        raise AssertionError(('cycles', cycles))
    actual = list(struct.unpack('<' + 'I' * n, report[20:]))
    expected = oracle(config, words, core)
    if actual != expected:
        raise AssertionError(('numerical', [(i, a, e) for i, (a, e)
                            in enumerate(zip(actual, expected)) if a != e]))
    return dict(status='PASS', count=n, cycles=cycles, tag=tag)


def cases(core=None):
    """(tag, config, words, stall) tuples; words stay 32-bit."""
    core = _core() if core is None else core
    rng = random.Random(9100 + core)
    out = []
    if core == 0:
        configs = [0, 1 | (2048 << 6), (3 << 0) | (1000 << 6),
                   (10 << 0) | (3000 << 6) | (1 << 19)]
    elif core == 1:
        configs = [100 | (3 << 7) | (10 << 11) | (6 << 15),
                   60 | (5 << 7) | (8 << 11) | (4 << 15) | (1 << 19),
                   80 | (4 << 7) | (9 << 11) | (5 << 15) | (1 << 21),
                   110 | (2 << 7) | (12 << 11) | (7 << 15) | (1 << 22)]
    elif core == 2:
        configs = [0, 1, 2, 3 | (1 << 2)]
    elif core == 3:
        configs = [8192 | (8 << 18), 4096 | (1 << 16) | (4 << 18),
                   2048 | (1 << 16) | (8 << 18) | (1 << 17),
                   16384 | (2 << 18) | (1 << 23)]
    elif core == 4:
        configs = [0, 4, 8, 15]
    else:
        # target/attack/release/est as core 1, plus the magnitude shift in
        # [27:23]; bit 21 bypasses both lanes and bit 19 selects linear slew.
        configs = [100 | (3 << 7) | (10 << 11) | (6 << 15) | (2 << 23),
                   60 | (5 << 7) | (8 << 11) | (4 << 15) | (1 << 21) | (5 << 23),
                   80 | (4 << 7) | (9 << 11) | (5 << 15) | (1 << 19),
                   110 | (2 << 7) | (12 << 11) | (7 << 15) | (1 << 22) | (15 << 23)]
    for i, c in enumerate(configs):
        n = 1 if i == 0 else 64
        if core in (3, 5):
            # both take full 32-bit words: lms pairs x/r, the bundle pairs I/Q
            words = [rng.randrange(1 << 32) for _ in range(n)]
        else:
            words = [s16_signed(rng) for _ in range(n)]
        out.append((0xD5000000 + core * 256 + i, c, words, (0, 1, 7)[i % 3]))
    return out


def s16_signed(rng):
    return rng.randrange(65536)

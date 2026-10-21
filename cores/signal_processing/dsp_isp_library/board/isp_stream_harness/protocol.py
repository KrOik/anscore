"""Strict 8x8 external frame protocol for isp_stream_harness (IMG1/IMR1).

Same packet/response contract as board/image_harness; the DUT is selected by
the frozen build's variant.json (field ``core``): 0 median, 1 convolution,
2 gradient.  Independent model oracles - never derived from DUT output.
"""
import json, random, struct, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1] if (HERE.parents[1] / 'isp').is_dir() else HERE.parent


def _core():
    for base in (HERE, Path.cwd()):
        v = base / 'variant.json'
        if v.exists():
            return json.loads(v.read_text()).get('core', 0)
    return 0


def _models(core):
    """Return module namespace for the per-core bit-exact model."""
    names = {0: 'median_model', 1: 'conv_model', 2: 'grad_model',
             3: 'morph_model', 4: 'bayer_reference'}
    name = names[core]
    src = {0: LIB / 'isp/median/model.py',
           1: LIB / 'isp/convolution/model.py',
           2: LIB / 'isp/gradient/model.py',
           3: LIB / 'isp/morphology/model.py',
           4: LIB / 'isp/bayer/models/reference.py'}[core]
    import importlib.util
    frozen = HERE / (name + '.py')
    if frozen.exists():
        src = frozen
    spec = importlib.util.spec_from_file_location(name, src)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _frame(words, bits):
    m = (1 << bits) - 1
    return [[w & m for w in words[y * 8:(y + 1) * 8]] for y in range(8)]


def make_packet(tag, config, words, stall=0):
    if len(words) != 64 or not 0 <= stall <= 7:
        raise ValueError('64 pixels/stall required')
    return (b'IMG1' + struct.pack('<IIBB', tag, config, 64, stall)
            + struct.pack('<64I', *words))


# Canned kernel table for CORE=1; must match isp_stream_harness.v conv branch
# (RTL literal lists model coeff[8] first - literal order is model-reversed).
KERNELS = {0: dict(coeff=[0, 0, 0, 0, 1, 0, 0, 0, 0], bias=0, shift=0),
           1: dict(coeff=[1, 2, 1, 2, 4, 2, 1, 2, 1], bias=0, shift=4),
           2: dict(coeff=[0, -1, 0, -1, 5, -1, 0, -1, 0], bias=0, shift=0),
           3: dict(coeff=[-1, 0, 1, -2, 0, 2, -1, 0, 1], bias=0, shift=0)}


def oracle(bits, config, words, padding=1, core=None):
    core = _core() if core is None else core
    if len(words) != 64:
        raise ValueError('image')
    image = _frame(words, bits)
    if core == 0:
        if config != 0:
            raise ValueError('median config')
        out = _models(0).median_image(image, k=3, pad=padding, bits=bits)
        flat = [out[y][x] for y in range(8) for x in range(8)]
    elif core == 1:
        sel = config & 15
        if config >> 4 or sel not in KERNELS:
            raise ValueError('conv config')
        kcfg = KERNELS[sel]
        out = _models(1).convolve(image, 3, kcfg['coeff'], kcfg['bias'],
                                  kcfg['shift'], bits, padding)
        flat = [out[y][x] for y in range(8) for x in range(8)]
    elif core == 2:
        scharr, l1 = (config >> 1) & 1, config & 1
        thr = (config >> 5) & ((1 << (bits + 5)) - 1)
        if config >> (5 + bits + 5):
            raise ValueError('grad config')
        out = _models(2).gradients(image, scharr=bool(scharr), l1=bool(l1),
                                   threshold=thr, pad=padding)
        flat = []
        for y in range(8):
            for x in range(8):
                g = out[y][x]
                flat.append((g['gx'] & 0x1FFF) | ((g['gy'] & 0x1FFF) << 13)
                            | ((g['magnitude'] & 0xF) << 26))
    elif core == 3:
        op, binary = config & 3, (config >> 2) & 1
        mask = (config >> 3) & 0x1FF
        if config >> 12 or mask == 0:
            raise ValueError('morph config')
        out = _models(3).morphology(image, 3, mask, op, bool(binary), padding)
        flat = [out[y][x] for y in range(8) for x in range(8)]
    elif core == 5:
        # Delivery bundle morph_median_stream: morphology's control surface, then
        # an unconfigurable 3x3 median over the morphology output frame.
        op, binary = config & 3, (config >> 2) & 1
        mask = (config >> 3) & 0x1FF
        if config >> 12 or mask == 0:
            raise ValueError('morph config')
        shapes = _models(3).morphology(image, 3, mask, op, bool(binary), padding)
        out = _models(0).median_image(shapes, k=3, pad=padding, bits=bits)
        flat = [out[y][x] for y in range(8) for x in range(8)]
    elif core == 4:
        ref = _models(4)
        cfa = config & 3
        ox = (config >> 2) & 1
        oy = (config >> 3) & 1
        reserved = (config >> 4) & 0xF
        if config >> 8 or reserved != 0:
            raise ValueError('bayer config')
        cfg = ref.Config(cfa=cfa, ox=ox, oy=oy, reserved=0)
        recs = ref.demosaic(image, cfg, bits=bits)
        flat = []
        for rec in recs:
            pixel = (rec['r'] << (2 * bits)) | (rec['g'] << bits) | rec['b']
            flat.append(pixel)
    else:
        raise ValueError('core')
    return [flat[i] | ((i % 8 == 7) << 30) | ((i == 0) << 31)
            for i in range(64)]


def verify(report, tag, config, words, bits, stall, padding=1, core=None):
    core = _core() if core is None else core
    if len(report) != 276 or report[:4] != b'IMR1':
        raise AssertionError('framing/count')
    rt, rc, n, flags, inc, outc, cycles = struct.unpack('<IIBBBBI', report[4:20])
    if (rt, rc, n, flags, inc, outc) != (tag, config, 64, 0, 64, 64):
        raise AssertionError('identity/flags/counters')
    if not 64 < cycles < 16384:
        raise AssertionError('replay cycle bounds')
    actual = list(struct.unpack('<64I', report[20:]))
    expected = oracle(bits, config, words, padding, core=core)
    if actual != expected:
        raise AssertionError(('pixel/sideband', [(i, a, e) for i, (a, e)
                              in enumerate(zip(actual, expected)) if a != e]))
    return dict(status='PASS', tag=tag, pixels=64, replay_cycles=cycles,
                cycles_per_pixel=cycles / 64, stall=stall)


def cases(bits, core=None):
    core = _core() if core is None else core
    rng = random.Random(7300 + bits + 97 * core)
    out = []
    if core == 0:
        configs = [0] * 16
    elif core == 1:
        configs = [i % 4 for i in range(16)]
    elif core in (3, 5):
        # op(0..3) x binary x three masks: cross, full3x3, diagonal
        # (core 5 is the morphology -> median delivery bundle; same control surface)
        masks = [0x1FF, 0x0AA, 0x149]
        configs = [(i & 3) | (((i >> 2) & 1) << 2)
                   | (masks[i % 3] << 3) for i in range(16)]
    elif core == 4:
        # cfa(0..3) x ox x oy
        configs = [(i & 3) | (((i >> 2) & 1) << 2) | (((i >> 3) & 1) << 3)
                   for i in range(16)]
    else:
        configs = [(i & 3) | (((i * 173) & ((1 << 12) - 1)) << 5)
                   for i in range(16)]
    for i, c in enumerate(configs):
        words = [rng.randrange(1 << bits) | (rng.randrange(1 << bits) << 16)
                 for _ in range(64)]
        for j in range(0, 64, 7):
            words[j] = rng.randrange(4)
        out.append((0xC6000000 + core * 256 + i, c, words, (0, 1, 7)[i % 3]))
    return out

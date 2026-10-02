"""SCL1/SCR1 variable-frame scaler protocol + independent golden oracle."""
import struct
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]
SCALE = LIB / 'isp' / 'scale'
sys.path.insert(0, str(SCALE))
from scale_model import scale_frame  # noqa: E402

MAXP = 2048
MAXW = 256


def make_packet(tag, dims, words, stall=0):
    """dims = (in_w,in_h,out_w,out_h); words = packed RGB u32 list."""
    iw, ih, ow, oh = dims
    count = iw * ih
    if len(words) != count:
        raise ValueError('count mismatch')
    if not (1 <= iw <= MAXW and 1 <= ow <= MAXW and
            1 <= ih <= 256 and 1 <= oh <= 256 and
            1 <= count <= MAXP and ow * oh <= MAXP and 0 <= stall <= 7):
        raise ValueError('dims/stall out of harness range')
    hdr = (b'SCL1' + struct.pack('<IHHHHHBB', tag, iw, ih, ow, oh,
                                 count, stall, 0))
    return hdr + struct.pack('<%dI' % count, *words)


def words_to_frame(words, iw, ih):
    return [[tuple((words[y * iw + x] >> s) & 0xFF for s in (16, 8, 0))
             for x in range(iw)] for y in range(ih)]


def oracle(dims, words):
    iw, ih, ow, oh = dims
    out = scale_frame(words_to_frame(words, iw, ih), iw, ih, ow, oh)
    res = []
    for y in range(oh):
        for x in range(ow):
            r, g, b = out[y][x]
            res.append((r << 16) | (g << 8) | b |
                       ((x == ow - 1) << 30) |
                       (((x == 0) and (y == 0)) << 31))
    return res


HEADER_FMT = '<IHHHHHHBBI'   # tag,in_w,in_h,out_w,out_h,in_cnt,out_cnt,flags,rsvd,cycles
HEADER_SIZE = 4 + struct.calcsize(HEADER_FMT)


def verify(report, tag, dims, words, stall):
    iw, ih, ow, oh = dims
    exp = oracle(dims, words)
    need = HEADER_SIZE + 4 * len(exp)
    if len(report) != need or report[:4] != b'SCR1':
        raise AssertionError('framing/length %d vs %d' %
                             (len(report), need))
    (rt, riw, rih, row, roh, inc, outc, flags, _r, cycles) = \
        struct.unpack(HEADER_FMT, report[4:HEADER_SIZE])
    if (rt, riw, rih, row, roh) != (tag, iw, ih, ow, oh):
        raise AssertionError('identity echo')
    if (inc, outc, flags) != (iw * ih, ow * oh, 0):
        raise AssertionError(('counters/flags', inc, outc, flags))
    if not (0 < cycles < 8000000):
        raise AssertionError('replay cycle bounds')
    actual = list(struct.unpack('<%dI' % len(exp), report[HEADER_SIZE:]))
    if actual != exp:
        bad = [(i, a, e) for i, (a, e) in enumerate(zip(actual, exp))
               if a != e]
        raise AssertionError(('pixel/sideband', bad[:8],
                              'total=%d' % len(bad)))
    return dict(status='PASS', tag=tag, dims=list(dims),
                in_pixels=iw * ih, out_pixels=ow * oh,
                replay_cycles=cycles,
                cycles_per_out=round(cycles / (ow * oh), 2), stall=stall)


def cases():
    """Return list of dicts: dims, kind, stall."""
    return [
        dict(dims=(32, 24, 64, 32), kind='gradient', stall=0), # 2x/1.33x up
        dict(dims=(64, 32, 48, 24), kind='random', stall=3),   # down
        dict(dims=(48, 40, 32, 32), kind='random', stall=5),   # 2/3x down
        dict(dims=(64, 16, 96, 16), kind='random', stall=4),   # 1.5x horiz
        dict(dims=(32, 8, 16, 16), kind='checker', stall=0),   # reconfig shape
        dict(dims=(40, 30, 52, 34), kind='random', stall=7),   # noninteger
        dict(dims=(48, 6, 12, 12), kind='random', stall=1),    # asymmetric
        dict(dims=(6, 48, 12, 12), kind='gradient', stall=2),  # asymmetric
        dict(dims=(1, 1, 8, 8), kind='random', stall=0),       # tiny
    ]


def make_frame(rng, w, h, kind):
    if kind == 'gradient':
        return [[((x * 255 // max(w - 1, 1)),
                  (y * 255 // max(h - 1, 1)),
                  ((x + y) * 127 // max(w + h - 2, 1)))
                 for x in range(w)] for y in range(h)]
    if kind == 'checker':
        return [[((255, 255, 255) if ((x + y) & 1) else (0, 0, 0))
                 for x in range(w)] for y in range(h)]
    return [[(rng.randrange(256), rng.randrange(256), rng.randrange(256))
             for x in range(w)] for y in range(h)]


def frame_to_words(frame):
    return [(r << 16) | (g << 8) | b
            for row in frame for (r, g, b) in row]

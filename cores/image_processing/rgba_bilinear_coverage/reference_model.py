"""Independent unbounded-integer oracle; CLI is a separately gated child.
No project imports. Preparation is never performed on import.
"""
from pathlib import Path
import argparse
import hashlib
import json
import random


def rne(n, d):
    q, r = divmod(n, d)
    return q + (2*r > d or (2*r == d and q % 2))


def filter_rgba(pixels, fx, fy):
    weights = ((256-fx)*(256-fy), fx*(256-fy), (256-fx)*fy, fx*fy)
    alpha = rne(sum(w*(p >> 24) for w, p in zip(weights, pixels)), 65536)
    colors = [rne(sum(w*(p >> 24)*((p >> shift) & 255) for w, p in zip(weights, pixels)),
                  255*65536) for shift in (16, 8, 0)]
    return (colors[0] << 24) | (colors[1] << 16) | (colors[2] << 8) | alpha


def compose(src, dst, mode):
    s = [(src >> shift) & 255 for shift in (24, 16, 8, 0)]
    d = [(dst >> shift) & 255 for shift in (24, 16, 8, 0)]
    error = 1 if mode > 12 else 2 if max(s[:3]) > s[3] else 3 if max(d[:3]) > d[3] else 0
    if error:
        return 0, error
    factors = ((0, 0), (255, 0), (0, 255), (255, 255-s[3]), (255-d[3], 255),
               (d[3], 0), (0, s[3]), (255-d[3], 0), (0, 255-s[3]),
               (d[3], 255-s[3]), (255-d[3], s[3]), (255-d[3], 255-s[3]), (255, 255))
    a, b = factors[mode]
    out = [min(255, (sv*a+dv*b+127)//255) for sv, dv in zip(s, d)]
    return sum(value << shift for value, shift in zip(out, (24, 16, 8, 0))), 0


def palette(index):
    alpha = (0, 1, 127, 128, 254, 255)[index % 6]
    return (alpha << 24) | (((index*73+255) & 255) << 16) | (((index*29+128) & 255) << 8) | ((index*11+1) & 255)


def texel(x, y, width, epoch):
    address = y*width+x
    return palette((address*37+y*11+epoch*17) & 255)


def core_rows(tag_width):
    rng = random.Random(4601)
    cases = []
    for value in (0, 1, 3, 127, 128, 254, 255):
        for fx, fy in ((0, 0), (128, 0), (0, 128), (128, 128), (255, 255), (64, 192)):
            cases.append(([value << 24 | 0x00ffffff, 0, 0, 0], fx, fy))
            cases.append(([0xff000000 | value << 16, 0, 0, 0], fx, fy))
    cases.extend([([0x01800000, 0, 0, 0], 64, 0), ([0x00ffffff]*4, 255, 255),
                  ([0xffffffff]*4, 255, 255), ([0xff010305, 0, 0, 0], 128, 0)])
    for _ in range(180):
        cases.append(([rng.getrandbits(32) for _ in range(4)], rng.randrange(256), rng.randrange(256)))
    for i, (pixels, fx, fy) in enumerate(cases):
        x, y, tag = (i*991) & 65535, (i*1301+65535) & 65535, (i*1777) & ((1 << tag_width)-1)
        yield ' '.join([*(f'{p:08x}' for p in pixels), str(fx), str(fy), str(x), str(y),
                        f'{tag:x}', f'{filter_rgba(pixels, fx, fy):08x}'])


def wrapper_rows(width, height, tag_width, epoch):
    rng = random.Random(4610+epoch)
    positions = [(0, 0), ((width-1)*256+255, (height-1)*256+255), (128, 128),
                 (min(width*256, 65535), 0), (0, min(height*256, 65535)), (65535, 65535)]
    positions += [(rng.randrange(65536), rng.randrange(65536)) for _ in range(8)]
    positions += [(rng.randrange(width*256), rng.randrange(height*256)) for _ in range(28)]
    i = 0
    for u, v in positions:
        for mode in (*range(13), 15):
            a = (0, 1, 128, 255)[i % 4]
            dst = (a << 24) | ((a//2) << 16) | ((a//3) << 8) | a
            if i % 17 == 0:
                dst = 0xff000001  # malformed premultiplied destination, error3 unless mode error1.
            x0, y0 = u//256, v//256
            oob = int(x0 >= width or y0 >= height)
            if oob:
                source = 0
            else:
                pixels = [texel(min(x0+dx, width-1), min(y0+dy, height-1), width, epoch)
                          for dy in (0, 1) for dx in (0, 1)]
                source = filter_rgba(pixels, u % 256, v % 256)
            expected, error = compose(source, dst, mode)
            x, y, tag = (i*397+epoch) & 65535, (65535-i*211) & 65535, (i*799+epoch) & ((1 << tag_width)-1)
            yield f'{u} {v} {dst:08x} {mode} {x} {y} {tag:x} {expected:08x} {error} {oob}'
            i += 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=('core_t1', 'core_t32', 'wrap_1x1_t1', 'wrap_5x4_t8', 'wrap_256x256_t32'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    profiles = {'core_t1': (0, 1, 1, 1), 'core_t32': (0, 1, 1, 32),
                'wrap_1x1_t1': (1, 1, 1, 1), 'wrap_5x4_t8': (1, 5, 4, 8),
                'wrap_256x256_t32': (1, 256, 256, 32)}
    wrapper, width, height, tag_width = profiles[args.profile]
    args.output.mkdir(exist_ok=False)
    files = {}
    counts = []
    for epoch in range(2 if wrapper else 1):
        rows = list(wrapper_rows(width, height, tag_width, epoch) if wrapper else core_rows(tag_width))
        name = f'vectors{epoch}.txt'
        data = (str(len(rows))+'\n'+'\n'.join(rows)+'\n').encode('ascii')
        (args.output/name).write_bytes(data)
        files[name] = dict(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data), rows=len(rows))
        counts.append(len(rows))
    expected = (dict(cases=1176, holds=4704, reset_fixtures=4, management_queries=38,
                     management_holds=174, responses=58, future_results=2, future_holds=8,
                     future_blocked=93, W=width, H=height, TAG=tag_width) if wrapper
                else dict(cases=268, holds=1072, reset_fixtures=6, fixture_outputs=6,
                          future_results=2, future_holds=8, future_blocked=73, TAG=tag_width))
    receipt = dict(schema='b46-c-integer-preparation-v1', profile=args.profile, files=files, expected_counters=expected,
                   cases=sum(counts), epochs=len(counts), numerical_preparations=1, oracle_definition_loads=1)
    (args.output/'preparation.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
    print('B46_C_PREP_PASS '+' '.join(f'{key}={value}' for key, value in expected.items()))


if __name__ == '__main__':
    main()

"""SPDX-License-Identifier: Apache-2.0. Direct, one-load independent oracle.

This file is executed only as an approved PREPARATION child. No project imports,
RTL invocation, stored golden frames, network access, or runtime source edits.
"""
import argparse
import hashlib
import json
from pathlib import Path

PROFILES = {
    'core_min': (1, 1, 8, 1, 0, 16),
    'core_thin': (2, 4, 8, 8, 0, 12),
    'core_five': (5, 5, 12, 8, 0, 20),
    'core_small': (7, 7, 10, 7, 0, 28),
    'core_tall': (1, 512, 10, 32, 0, 8),
    'core_max': (256, 256, 12, 32, 0, 2),
    'bayer_small': (7, 7, 10, 7, 1, 28),
    'bayer_wide': (512, 1, 8, 32, 1, 8),
}
PAIR_OFFSETS = (((-2, 0), (2, 0)), ((0, -2), (0, 2)),
                ((-2, -2), (2, 2)), ((2, -2), (-2, 2)))


def repair_frame(frame, width, height, enable, base, shift):
    result, flags, directions = list(frame), [0] * len(frame), [0] * len(frame)
    if not enable:
        return result, flags, directions
    for y in range(2, height - 2):
        for x in range(2, width - 2):
            pairs = [(frame[(y + a[1]) * width + x + a[0]],
                      frame[(y + b[1]) * width + x + b[0]]) for a, b in PAIR_OFFSETS]
            # Tuple ordering expresses the tie rule independently of RTL's
            # cascaded strict comparisons. The full uncorrected frame is read.
            gradient, direction, predictor = min((abs(a - b), d, (a + b + 1) // 2)
                                                  for d, (a, b) in enumerate(pairs))
            neighbors = [value for pair in pairs for value in pair]
            center = frame[y * width + x]
            excess = max(min(neighbors) - center, center - max(neighbors), 0)
            if excess > base + (gradient >> shift):
                p = y * width + x
                result[p], flags[p], directions[p] = predictor, 1, direction
    return result, flags, directions


def bilinear(frame, width, height, pattern, bits):
    def at(x, y):
        return frame[min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))]
    result = []
    for y in range(height):
        for x in range(width):
            site = (((y & 1) << 1) | (x & 1)) ^ pattern
            c = at(x, y)
            horizontal = (at(x - 1, y) + at(x + 1, y)) // 2
            vertical = (at(x, y - 1) + at(x, y + 1)) // 2
            cross = (at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1)) // 4
            diagonal = sum(at(x + dx, y + dy) for dx in (-1, 1) for dy in (-1, 1)) // 4
            if site == 0:
                red, green, blue = c, cross, diagonal
            elif site == 3:
                red, green, blue = diagonal, cross, c
            elif site == 1:
                red, green, blue = horizontal, c, vertical
            else:
                red, green, blue = vertical, c, horizontal
            result.append((red << (2 * bits)) | (green << bits) | blue)
    return result


def make_case(index, width, height, bits, tag_w, cases):
    maximum = (1 << bits) - 1
    level = maximum // 3
    frame = [level] * (width * height)
    enable, base, shift = 1, 0, index & 3
    pattern, fault = index & 3, 0
    tag = (0xF13579BD + index * 0x1020305) & ((1 << tag_w) - 1)
    if index == 0:
        frame = [0] * len(frame)
    elif index == 1:
        frame = [maximum] * len(frame)
    elif index == 2:
        frame = [((x * 7 + y * 11) % (maximum + 1)) for y in range(height) for x in range(width)]
    elif index == 3:
        frame = [((y & 1) * 2 + (x & 1)) * (maximum // 4) for y in range(height) for x in range(width)]
    if width >= 5 and height >= 5 and index >= 4:
        x, y = width // 2, height // 2
        pairs = [(level, level)] * 4
        center = maximum if index != 5 else 0
        if 6 <= index <= 9:
            winner = index - 6
            pairs = [(level - 17, level + 23)] * 4
            pairs[winner] = (level - 9, level - 8)  # odd sum checks half-up
        elif index == 10:
            pairs = [(level - 20 + d * 10, level - 20 + d * 10) for d in range(4)]
        elif index == 11:
            pairs = [(level - 20, level + 20), (level - 15, level + 15),
                     (level - 10, level - 10), (level + 10, level + 10)]
        elif 12 <= index <= 14:
            pairs = [(level, level)] * 4
            base = 7
            center = level + (7 if index == 12 else 8 if index == 13 else 6)
        elif index == 15:
            pairs = [(level - 100, level + 100), (level, level), (level, level), (level, level)]
            center = level + 99  # inside envelope despite a distant median
        elif index == 16:
            pairs = [(level - 17, level + 23)] * 4
            base, shift, center = maximum - 10, 0, maximum
        elif index == 17:
            pairs = [(level, level + 1)] * 4
        elif index == 18:
            base = maximum
        elif index == 19:
            enable = 0
        elif 20 <= index <= 23:
            pairs = [(level - 10, level + 10)] * 4
            base, shift = 1, index - 20
            center = level + 10 + 1 + (20 >> shift) + (index & 1)
        for pair, offsets in zip(pairs, PAIR_OFFSETS):
            for value, (dx, dy) in zip(pair, offsets):
                frame[(y + dy) * width + x + dx] = value
        frame[y * width + x] = center
        # An outer-border impulse must pass unchanged; donors are never repaired
        # and fed back to the center oracle.
        frame[0], frame[-1] = maximum, 0
    if cases == 2:
        enable, base, shift = int(index == 0), 2, 2
        frame = [((x * 13 + y * 29 + x * y * 3) & maximum)
                 for y in range(height) for x in range(width)]
        for y in (2, height // 2, height - 3):
            for x in (2, width // 2, width - 3):
                frame[y * width + x] = maximum if (x + y) & 1 else 0
    elif cases >= 8 and index >= cases - 3:
        fault = index - (cases - 3) + 1
    return frame, enable, base, shift, tag, pattern, fault


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', required=True, choices=PROFILES)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    width, height, bits, tag_w, example, cases = PROFILES[args.profile]
    assert not args.output.exists(), 'Preparation outputs are once-only'
    args.output.mkdir(parents=True)
    vectors = args.output / 'vectors.txt'
    pixels = width * height * cases
    metadata = []
    with vectors.open('x', encoding='ascii', newline='\n') as stream:
        stream.write(f'{cases} {width*height} {pixels}\n')
        for index in range(cases):
            frame, enabled, base, shift, tag, pattern, fault = make_case(index, width, height, bits, tag_w, cases)
            repaired, flags, directions = repair_frame(frame, width, height, enabled, base, shift)
            golden = bilinear(repaired, width, height, pattern, bits) if example else repaired
            stream.write(f'{enabled} {base} {shift} {tag} {pattern} {fault} {sum(flags)}\n')
            for source, expected, applied, direction in zip(frame, golden, flags, directions):
                stream.write(f'{source} {expected} {0 if example else applied} {0 if example else direction}\n')
            metadata.append(dict(index=index,pattern=pattern,fault=fault,repaired=sum(flags)))
    counters = dict(cases=cases, pixels=pixels, reset_checks=3)
    content = vectors.read_bytes()
    receipt = dict(schema='anscore-b48-c-preparation-v1',profile=args.profile,
        numerical_preparations=1,oracle_definition_loads=1,expected_counters=counters,
        cases=cases,case_metadata=metadata,files={'vectors.txt':dict(
            sha256=hashlib.sha256(content).hexdigest(),bytes=len(content),rows=1+cases+pixels)})
    (args.output / 'preparation.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print('B48_PREP ' + ' '.join(f'{k}={v}' for k,v in counters.items()))


if __name__ == '__main__':
    main()

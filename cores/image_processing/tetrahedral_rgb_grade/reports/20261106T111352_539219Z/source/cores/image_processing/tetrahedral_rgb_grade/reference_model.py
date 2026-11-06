"""SPDX-License-Identifier: Apache-2.0. Independent rational tetrahedral oracle.

Preparation is deliberately a standalone child, never imported by the runner.
No source preparation or oracle call is permitted before the independent gate.
"""
import argparse
from fractions import Fraction
import hashlib
import itertools
import json
from pathlib import Path
import random


def interpolate(rgb, table, bits, grid):
    maximum, cells = (1 << bits) - 1, 1 << grid
    positions = [Fraction(value * cells, maximum) for value in rgb]
    lower = [min(value.numerator // value.denominator, cells - 1) for value in positions]
    fractions = [value - base for value, base in zip(positions, lower)]
    order = sorted(range(3), key=lambda axis: (-fractions[axis], axis))
    f0, f1, f2 = (fractions[axis] for axis in order)
    weights = [1 - f0, f0 - f1, f1 - f2, f2]
    coordinates = [list(lower)]
    for axis in order:
        vertex = list(coordinates[-1]); vertex[axis] += 1; coordinates.append(vertex)
    vertices = [table[r + (cells + 1) * g + (cells + 1) ** 2 * b] for r, g, b in coordinates]
    result = []
    for channel in range(3):
        value = sum(weight * vertex[channel] for weight, vertex in zip(weights, vertices))
        quotient, remainder = divmod(value.numerator, value.denominator)
        result.append(quotient + (2 * remainder >= value.denominator))
    return tuple(result)


def pack(rgb, bits):
    return (rgb[0] << (2 * bits)) | (rgb[1] << bits) | rgb[2]


def main():
    parser = argparse.ArgumentParser()
    for name in ('width', 'height', 'bits', 'grid', 'tag', 'wrap'):
        parser.add_argument('--' + name, type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    maximum, cells = (1 << args.bits) - 1, 1 << args.grid
    randomizer = random.Random(0x44C0 + args.bits * 13 + args.grid)
    first, second = [], []
    for b in range(cells + 1):
        for g in range(cells + 1):
            for r in range(cells + 1):
                first.append(((r * r * maximum // (cells * cells) + 13 * g + 7 * b) % (maximum + 1),
                    (g * r * maximum // (cells * cells) + 11 * b + 5 * r) % (maximum + 1),
                    (b * b * maximum // (cells * cells) + 19 * r + 3 * g) % (maximum + 1)))
                second.append(tuple(randomizer.randrange(maximum + 1) for _ in range(3)))
    tables = [first, second, [(maximum, maximum // 3, 0)] * len(first)]
    probes = [(0, 0, 0), (maximum, maximum, maximum), (maximum, 0, 0), (0, maximum, 0), (0, 0, maximum)]
    probes += list(itertools.permutations((1, 2, 3)))
    probes += [(2, 2, 1), (2, 1, 2), (1, 2, 2), (maximum // 2,) * 3]
    pixels = (probes + [tuple(randomizer.randrange(maximum + 1) for _ in range(3))
        for _ in range(args.width * args.height)])[:args.width * args.height]
    expected = []
    for table in tables:
        for rgb in pixels:
            result = interpolate(rgb, table, args.bits, args.grid)
            expected.append((77 * result[0] + 150 * result[1] + 29 * result[2]) >> 8
                if args.wrap else pack(result, args.bits))
    args.output.mkdir(parents=True, exist_ok=False)
    outputs = {'tables.hex': [pack(rgb, args.bits) for table in tables for rgb in table],
               'pixels.hex': [pack(rgb, args.bits) for rgb in pixels], 'expected.hex': expected}
    files = {}
    for name, values in outputs.items():
        raw = ''.join(format(value, 'x') + '\n' for value in values).encode()
        (args.output / name).write_bytes(raw)
        files[name] = dict(sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw), words=len(values))
    data = dict(schema='anscore-b44-tetra-preparation-v1', oracle_definition_loads=1,
        numerical_preparations=1, profile={key: getattr(args, key) for key in ('width','height','bits','grid','tag','wrap')},
        files=files, expected_counters=dict(frames=13 + args.wrap, faults=1, config_faults=2,
            invalids=10 + args.wrap, resets=9 + args.wrap,
            outputs=(13 + args.wrap) * args.width * args.height + int(args.width * args.height > 1),
            early=(13 + args.wrap) * (args.width * args.height - 1) + int(args.width * args.height > 1)))
    (args.output / 'preparation.json').write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    print('B44_C_PREP_PASS oracle_definition_loads=1 numerical_preparations=1')


if __name__ == '__main__':
    main()

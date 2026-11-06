"""One isolated preparation loads the integer definition once; no tool execution."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import random


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=['tiny', 'small', 'maximum', 'example'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('group_pointwise_definition', Path(__file__).parents[1] / 'model/oracle.py')
    oracle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oracle)
    rng = random.Random(473001 + ['tiny', 'small', 'maximum', 'example'].index(args.profile))
    lines = []
    if args.profile == 'example':
        counts = [1, 7, 64]
        lines.append(str(len(counts)))
        for frame, pixels in enumerate(counts):
            lines.append(f'{pixels} {frame + 31}')
            values = [[rng.randrange(256) for _ in range(6)] for _ in range(pixels)]
            values[0] = [0, 255, 128, 255, 0, 128]
            for row in values:
                lines.append(f'{sum(value << (8 * i) for i, value in enumerate(row)):012x} {oracle.rgb_projection(row):08x}')
        scored = sum(counts)
    else:
        groups, cap_i, cap_o, cap_p = {'tiny': (1, 1, 1, 1), 'small': (3, 9, 3, 7),
                                      'maximum': (8, 128, 8, 4096)}[args.profile]
        shapes = [(1, 1, 1, 0), (1, 1, 1, 1), (cap_p, 1, 1, 1),
                  (1, cap_i, cap_o, 0), (2 if cap_p > 1 else 1, min(9, cap_i), cap_o, 1)]
        lines.append(str(len(shapes)))
        scored = 0
        for frame, (pixels, ni, no, shuffle) in enumerate(shapes):
            xzero = [0, 255, 128, 1, 127][frame]
            lines.append(f'{pixels} {ni} {no} {xzero} {shuffle} {frame + 1}')
            matrix = []
            for group in range(groups):
                block = []
                for row in range(no):
                    bias = [0, -2147483648, 2147483647, -1, 1][(group + row + frame) % 5]
                    scale = [1, 65535, 0, 3, 2][(2 * group + row + frame) % 5]
                    shift = [0, 1, 31, 3, 7][(group + 2 * row + frame) % 5]
                    zero = [-128, 127, 1, -1, 0][(group + row + frame) % 5]
                    # Include exact +/- half ties without a huge dominating bias.
                    if frame < 2:
                        bias, scale, shift, zero = (-1 if frame else 1), 1, 1, (1 if frame else -1)
                    weights = [rng.randrange(-8, 8) for _ in range(ni)]
                    if frame < 2:
                        weights = [0] * ni
                    block.append((bias, scale, shift, zero, weights))
                    lines.append(f'{bias} {scale} {shift} {zero}')
                    for offset in range(0, ni, 8):
                        packed = sum((weights[i] & 15) << (4 * (i - offset))
                                     for i in range(offset, min(ni, offset + 8)))
                        # Padding poison must be ignored in the final packed word.
                        for i in range(min(8, ni - offset), 8):
                            packed |= 8 << (4 * i)
                        lines.append(f'{packed:08x}')
                matrix.append(block)
            samples = [[rng.randrange(256) for _ in range(groups * ni)] for _ in range(pixels)]
            samples[0][0] = 0
            samples[-1][-1] = 255
            for values in samples:
                lines.extend(str(value) for value in values)
            expected = oracle.evaluate(samples, groups, ni, no, xzero, shuffle, matrix)
            lines.extend(' '.join(map(str, row)) for row in expected)
            scored += len(expected)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='ascii', newline='\n') as stream:
        stream.write('\n'.join(lines) + '\n')
    payload = args.output.read_bytes()
    receipt = dict(profile=args.profile, scored=scored, frames=(len(counts) if args.profile == 'example' else len(shapes)),
                   bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
    args.output.with_suffix('.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='ascii')
    print('PREP_GROUP_POINTWISE ' + json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()

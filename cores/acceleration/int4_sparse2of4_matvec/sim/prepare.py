"""Bounded deterministic vectors; invoked only by the reviewed finite plan."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import random


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=('tiny', 'small', 'maximum', 'example'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('sparse_definition', Path(__file__).parents[1] / 'model/oracle.py')
    oracle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oracle)
    rng = random.Random(480701 + ('tiny', 'small', 'maximum', 'example').index(args.profile))
    lines = []
    if args.profile == 'example':
        vectors = [[0, 0, 0, 0], [255, 0, 128, 1], [0, 255, 0, 255],
                   [1, 0, 1, 0], [0, 1, 0, 1], [255, 255, 255, 255]]
        vectors += [[rng.randrange(256) for _ in range(4)] for _ in range(58)]
        lines.append(str(len(vectors)))
        for tag, vector in enumerate(vectors):
            result = oracle.example(vector)
            lines.append(f'{sum(x << (8*i) for i,x in enumerate(vector)):08x} {tag}')
            lines.extend(f'{score} {index}' for score, index in result)
        scored, frames = 2 * len(vectors), len(vectors)
    else:
        mr, mc = {'tiny': (1, 1), 'small': (3, 7), 'maximum': (64, 1024)}[args.profile]
        shapes = [(1, 1), (1, 1), (mr, mc), (mr, mc)]
        shapes += [(min(mr, 6), min(mc, size)) for size in (2, 3, 4, 5, 7, mc)]
        lines.append(str(len(shapes)))
        scored = 0
        matrix = None
        for frame, (nr, nc) in enumerate(shapes):
            configure = int(frame != 3)
            xzero = (0, 255, 255, 0, 128, 1, 127, 254, 13, 250)[frame]
            lines.append(f'{nr} {nc} {xzero} {frame+1} {configure}')
            if configure:
                matrix = []
                for row in range(nr):
                    bias = (0, -2147483648, 2147483647, -255, 255, -1)[row % 6]
                    scale = (1, 65535, 3, 0, 1, 2)[row % 6]
                    shift = (12, 31, 31, 5, 1, 3)[row % 6]
                    zero = (0, 127, -128, 1, -1, 13)[row % 6]
                    if frame < 2:
                        bias, scale, shift, zero = (1 if frame == 0 else -1), 1, 1, 1
                    groups = []
                    for g in range((nc + 3) // 4):
                        pattern = (g + row + frame) % 6
                        w0, w1 = rng.randrange(-8, 8), rng.randrange(-8, 8)
                        if frame < 2:
                            w0 = w1 = 0
                        groups.append((pattern, w0, w1))
                    matrix.append((bias, scale, shift, zero, groups))
                    lines.append(f'{bias} {scale} {shift} {zero}')
                    lines.extend(f'{pattern} {((b & 15) << 4) | (a & 15):02x}' for pattern, a, b in groups)
            vector = [rng.randrange(256) for _ in range(nc)]
            vector[0] = 0
            vector[-1] = 255
            lines.extend(map(str, vector))
            lines.extend(' '.join(map(str, y)) for y in oracle.evaluate(vector, xzero, matrix))
            scored += nr
        frames = len(shapes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='ascii', newline='\n') as stream:
        stream.write('\n'.join(lines) + '\n')
    raw = args.output.read_bytes()
    summary = dict(profile=args.profile, frames=frames, scored=scored,
                   sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw))
    with args.output.with_suffix('.json').open('x', encoding='ascii', newline='\n') as stream:
        json.dump(summary, stream, indent=2)
        stream.write('\n')
    print('PREP_SPARSE2OF4 ' + json.dumps(summary, sort_keys=True))


if __name__ == '__main__':
    main()

"""Generate independent bit-exact CORDIC vectors from the Python model."""
import argparse
import itertools
import random
from pathlib import Path
from golden_model import cordic

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--board-output', type=Path)
args = parser.parse_args()
rng = random.Random(0xC0D1C)
cases = list(itertools.product((0, 1), (-32768, -1, 0, 1, 32767),
                              (-32768, 0, 32767), (-32768, -25737, -25736, 0, 25736, 25737, 32767)))
while len(cases) < 4096:
    cases.append((rng.randrange(2), *(rng.randrange(-32768, 32768) for _ in range(3))))
rows = []
for mode, x, y, z in cases:
    xo, yo, zo = cordic(x, y, z, mode)
    inputs = (mode << 48) | ((x & 65535) << 32) | ((y & 65535) << 16) | (z & 65535)
    expected = ((zo & 0x3ffff) << 32) | ((yo & 65535) << 16) | (xo & 65535)
    rows.append(f'{(inputs << 50) | expected:025x}')
args.output.write_text('\n'.join(rows)+'\n', encoding='ascii')
print('Generated 4096 independent CORDIC vectors, including quadrant/saturation boundaries')
if args.board_output:
    rows=[]
    for i in range(32):
        xo,yo,zo=cordic(i*1024-16384,i*733-12000,i*2000-31000,i&1)
        rows.append(f'{((zo & 0x3ffff)<<32)|((yo & 65535)<<16)|(xo & 65535):016x}')
    args.board_output.write_text('\n'.join(rows)+'\n',encoding='ascii')
    print('Generated 32 independent full-rate board results')

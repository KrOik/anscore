"""Generate nonlinear lookup fixtures for memory implementation checks."""
import argparse
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--input-width', type=int, required=True)
p.add_argument('--output-width', type=int, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if not 1 <= a.input_width <= 12 or not 1 <= a.output_width <= 16:
    p.error('fixture supports address width 1..12 and data width 1..16')
a.output.mkdir(parents=True, exist_ok=False)
mask = (1 << a.output_width)-1
values = [((i*i*13) ^ (i<<3) ^ (i>>2) ^ 0x539a) & mask for i in range(1<<a.input_width)]
(a.output/'custom.mem').write_text(''.join(f'{v:x}\n' for v in values))

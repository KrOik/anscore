import math
from pathlib import Path
root=Path(__file__).resolve().parent
root.joinpath('trig.mem').write_text(''.join(f'{(round(math.cos(math.radians(t))*16384)&65535):04x}{(round(math.sin(math.radians(t))*16384)&65535):04x}\n' for t in range(180)))

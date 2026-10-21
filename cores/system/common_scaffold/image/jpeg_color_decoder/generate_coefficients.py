"""Generate the original orthonormal IDCT matrix, signed Q26/28-bit entries."""
from pathlib import Path
import math
HERE=Path(__file__).resolve().parent
values=[round((1/math.sqrt(8) if u==0 else .5)*math.cos((2*x+1)*u*math.pi/16)*(1<<26)) for x in range(8) for u in range(8)]
(HERE/'idct_coeff.hex').write_text('\n'.join(f'{v&((1<<28)-1):07x}' for v in values)+'\n')

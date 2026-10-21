from pathlib import Path
import sys,tempfile
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3]
sys.path.insert(0,str(COMMON/'integration'))
from tooling import execute
sources=[HERE/'candidate_v7/cip_image_clahe_frame.v',HERE/'tb_serial_fraction.v',*[COMMON/'image/histogram/rtl'/n for n in ['img_hist_ratio_u8.v','img_hist_clahe_interp.v','img_hist_serial_multiply.v']]]
with tempfile.TemporaryDirectory(prefix='clahe_fraction_') as t:
 binary=Path(t)/'fraction.vvp';output=execute(['iverilog','-g2012','-s','tb_serial_fraction','-o',binary,*sources],HERE,HERE/'serial_fraction_compile.log')
 if output.strip():raise RuntimeError(output)
 output=execute(['vvp',binary],HERE,HERE/'serial_fraction_simulation.log');print(output.strip())
 if 'CLAHE_SERIAL_FRACTION PASS' not in output:raise RuntimeError('missing PASS')

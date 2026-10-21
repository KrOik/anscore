from pathlib import Path
import sys,tempfile
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3]
sys.path.insert(0,str(COMMON/'integration'))
from tooling import execute
sources=[HERE/'candidate_v3/cip_image_clahe.v',HERE/'candidate_v3/cip_image_clahe_frame.v',HERE/'tb_coordinate_domain.v',*[COMMON/'image/histogram/rtl'/n for n in ['img_hist_ratio_u8.v','img_hist_clahe_interp.v','img_hist_serial_multiply.v']]]
with tempfile.TemporaryDirectory(prefix='clahe_domain_') as t:
 binary=Path(t)/'domain.vvp';execute(['iverilog','-g2012','-s','tb_coordinate_domain','-o',binary,*sources],HERE,HERE/'coordinate_domain_v3_compile.log')
 output=execute(['vvp',binary],HERE,HERE/'coordinate_domain_v3_simulation.log');print(output.strip())
 if 'CLAHE_COORDINATE_DOMAIN PASS' not in output:raise RuntimeError('missing PASS')

"""Retain original fixture325 as a narrow regression for the lost CDF shortcut."""
from pathlib import Path
import sys,tempfile
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3];SV=COMMON/'signal_video'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(SV))
from tooling import execute
from run_clahe_tests import fixtures
sources=[HERE/'candidate_v5/cip_image_clahe.v',HERE/'candidate_v5/cip_image_clahe_frame.v',SV/'sim/tb_cip_image_clahe.v',*[COMMON/'image/histogram/rtl'/n for n in ['img_hist_ratio_u8.v','img_hist_clahe_interp.v','img_hist_serial_multiply.v']]]
with tempfile.TemporaryDirectory(prefix='clahe_unit255_') as t:
 root=Path(t);original=root/'original';original.mkdir();fixtures(original,8,8)
 def read(n):return [int(x,16) for x in (original/(n+'.hex')).read_text().split()]
 records=read('commands');ip=ep=0
 for i in range(325):
  row=records[i*10:(i+1)*10];ip+=row[9];ep+=0 if row[8] in [1,2] else row[9]
 row=records[3250:3260];n=row[9]
 for name,values in [('commands',row),('inputs',read('inputs')[ip:ip+n]),('auxiliary',read('auxiliary')[ip:ip+n]),('expected',read('expected')[ep:ep+n])]:
  (root/(name+'.hex')).write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
 binary=root/'unit.vvp';compile_text=execute(['iverilog','-g2012','-s','tb_cip_image_clahe','-Ptb_cip_image_clahe.DW=8','-Ptb_cip_image_clahe.GB=8','-o',binary,*sources],HERE,HERE/'unit_tiles325_compile.log')
 if compile_text.strip():raise RuntimeError(compile_text)
 output=execute(['vvp',binary,f'+folder={root}','+commands=1',f'+pixels={n}',f'+outputs={n}'],HERE,HERE/'unit_tiles325_simulation.log');print(output.strip())
 if 'CLAHE PASS width=8' not in output:raise RuntimeError('missing PASS')

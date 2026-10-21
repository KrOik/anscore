"""Isolated matched-tool no-ALU synthesis; no P&R or board operation."""
import os,sys,json,subprocess,collections,hashlib
from pathlib import Path
from datetime import datetime
BASE=Path(__file__).resolve().parents[1]; ROOT=BASE.parents[3]
OUT=BASE/'evidence'/('synth_variants_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir()
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite'
env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
rtl=BASE/'rtl/statistics_stream.sv'; reports=[]
for variant in [0,1]:
 d=OUT/str(variant);d.mkdir()
 command=f'read_verilog -sv {rtl.as_posix()}; chparam -set LOGIC_SQUARE {variant} statistics_stream; synth_gowin -noalu -family gw2a -top statistics_stream -json core.json; stat'
 (d/'command.txt').write_text(command+'\n')
 p=subprocess.run([str(tool/'bin/yosys.exe'),'-p',command],cwd=d,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (d/'yosys.log').write_text(p.stdout)
 if p.returncode:raise RuntimeError(f'variant {variant} failed: {d}')
 j=json.loads((d/'core.json').read_text());c=collections.Counter(v['type'] for v in j['modules']['statistics_stream']['cells'].values())
 report={'LOGIC_SQUARE':variant,'cells':dict(c),'lut1_4':sum(c[f'LUT{k}'] for k in range(1,5)),
 'ff':sum(v for k,v in c.items() if k.startswith('DFF')),
 'dsp':sum(v for k,v in c.items() if k.startswith(('MULT','PADD','ALU54'))),
 'bram':sum(v for k,v in c.items() if k.startswith(('DPX','SPX','SDPX')))}
 (d/'resources.json').write_text(json.dumps(report,indent=2));reports.append(report)
 if variant==1:assert report['dsp']==0,report
summary={'status':'PASS','source_sha256':hashlib.sha256(rtl.read_bytes()).hexdigest(),'variants':reports,
 'scope':'core-only synthesis; excludes wrapper, chain, P&R and hardware timing'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print(json.dumps(summary,indent=2))

"""Isolated Gowin mapping; no P&R or board claim."""
import os,json,subprocess,hashlib,collections
from pathlib import Path
from datetime import datetime
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[3]
OUT=BASE/'evidence'/('synth_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir()
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
source=BASE/'rtl/polyphase_resampler.sv';reports=[]
for taps in [16,128]:
 d=OUT/str(taps);d.mkdir()
 command=f'read_verilog -sv {source.as_posix()}; chparam -set MAX_TAPS {taps} polyphase_resampler; synth_gowin -noalu -family gw2a -top polyphase_resampler -json core.json; stat'
 (d/'command.txt').write_text(command+'\n')
 p=subprocess.run([str(tool/'bin/yosys.exe'),'-p',command],cwd=d,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (d/'yosys.log').write_text(p.stdout)
 if p.returncode:raise RuntimeError(str(d))
 design=json.loads((d/'core.json').read_text());counts=collections.Counter(c['type'] for c in design['modules']['polyphase_resampler']['cells'].values())
 report={'max_taps':taps,'cells':dict(counts),'lut1_4':sum(counts[f'LUT{k}'] for k in range(1,5)),
 'ff':sum(v for k,v in counts.items() if k.startswith('DFF')),
 'dsp':sum(v for k,v in counts.items() if k.startswith(('MULT','PADD','ALU54'))),
 'bram':sum(v for k,v in counts.items() if k.startswith(('DPX','SPX','SDPX'))),
 'wide_mux':sum(v for k,v in counts.items() if k.startswith('MUX'))}
 (d/'resources.json').write_text(json.dumps(report,indent=2));reports.append(report)
summary={'status':'PASS','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'configurations':reports,
 'scope':'isolated mapped resources; no board pin fit, routed timing or physical acceptance'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print(json.dumps(summary,indent=2))

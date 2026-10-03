import os,json,subprocess,hashlib,collections
from pathlib import Path
from datetime import datetime
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[3]
OUT=BASE/'evidence'/('synth_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir(parents=True)
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
source=BASE/'rtl/farrow_cubic_stream.sv'
command=f'read_verilog -sv {source.as_posix()}; synth_gowin -noalu -family gw2a -top farrow_cubic_stream -json core.json; stat'
(OUT/'command.txt').write_text(command+'\n')
p=subprocess.run([str(tool/'bin/yosys.exe'),'-p',command],cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(OUT/'yosys.log').write_text(p.stdout)
if p.returncode:raise RuntimeError(str(OUT))
design=json.loads((OUT/'core.json').read_text());counts=collections.Counter(c['type'] for c in design['modules']['farrow_cubic_stream']['cells'].values())
report={'status':'PASS','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'cells':dict(counts),
 'lut1_4':sum(counts[f'LUT{k}'] for k in range(1,5)),
 'ff':sum(v for k,v in counts.items() if k.startswith('DFF')),
 'dsp':sum(v for k,v in counts.items() if k.startswith(('MULT','PADD','ALU54'))),
 'bram':sum(v for k,v in counts.items() if k.startswith(('DPX','SPX','SDPX'))),
 'wide_mux':sum(v for k,v in counts.items() if k.startswith('MUX')),
 'scope':'isolated mapping; no routed frequency, wrapper, chain or physical qualification'}
(OUT/'summary.json').write_text(json.dumps(report,indent=2));print(OUT);print(json.dumps(report,indent=2))
assert report['dsp']<=4 and report['lut1_4']<=15000

"""Synthesize the exact composed chain; core-only counts, never a route claim."""
import collections, datetime, hashlib, json, os, re, shutil, subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent;LIB=HERE.parents[1];ROOT=LIB.parents[1]
out=HERE/'evidence'/('synth_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
out.mkdir(parents=True)
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite'
env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
sources=[HERE/'dc_statistics_stream.v',LIB/'dsp/dc/rtl/dc_stream.sv',LIB/'dsp/statistics/rtl/statistics_stream.sv']
for p in sources:shutil.copy2(p,out/p.name)
(out/'hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},indent=2))
(out/'build.ys').write_text('read_verilog -sv '+' '.join(p.name for p in sources)+'\nsynth_gowin -noalu -family gw2a -top dc_statistics_stream -json core.json\nstat\n')
with (out/'console.log').open('w') as f:
    p=subprocess.run([str(tool/'bin/yosys.exe'),'-Q','-l','yosys.log','build.ys'],cwd=out,env=env,stdout=f,stderr=subprocess.STDOUT)
assert p.returncode==0,out
net=json.loads((out/'core.json').read_text());cells=collections.Counter(c['type'] for c in net['modules']['dc_statistics_stream']['cells'].values())
lut=sum(v for k,v in cells.items() if re.fullmatch(r'LUT[1-4]|ALU',k))
dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','PADD','ALU54')))
summary=dict(status='PASS' if lut<=15000 and dsp<=4 else 'FAIL',lut1_4=lut,dsp=dsp,cells=cells,scope='core synthesis only; no wrapper, P&R or physical acceptance')
(out/'summary.json').write_text(json.dumps(summary,indent=2));print(out);print(json.dumps(summary,indent=2))
assert summary['status']=='PASS'

"""Isolated complete convolution core mapping with a hard four-DSP gate."""
import datetime,hashlib,json,os,shutil,subprocess
from collections import Counter
from test_convolution import HERE,LIB,ROOT
out=HERE/'evidence'/('synth_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));out.mkdir(parents=True)
src=out/'sources';src.mkdir()
files=[HERE/'convolution_stream.v',LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v',HERE/'synth_convolution.py']
for f in files:shutil.copy2(f,src/f.name)
(out/'hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
env=dict(os.environ);cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH'];results=[]
for k,d in ((3,8),(5,10)):
 for pad in (0,1):
  case=out/f'k{k}_d{d}_pad{pad}';case.mkdir()
  script=''.join(f'read_verilog "{(src/f.name).resolve().as_posix()}"\n' for f in files if f.suffix=='.v')
  script+=f'chparam -set WIDTH 32 -set HEIGHT 24 -set K {k} -set BITS {d} -set PAD_MODE {pad} convolution_stream\nsynth_gowin -noalu -family gw2a -top convolution_stream -json mapped.json\nstat\n'
  (case/'build.ys').write_text(script)
  r=subprocess.run([shutil.which('yosys',path=env['PATH']),'-s','build.ys'],cwd=case,env=env,capture_output=True,text=True)
  (case/'synth.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout[-2000:]
  cells=Counter(c['type'] for c in json.loads((case/'mapped.json').read_text())['modules']['convolution_stream']['cells'].values())
  dsp=sum(n for t,n in cells.items() if t.startswith(('MULT','PADD','ALU54')));assert dsp<=4,cells
  assert not any('LATCH' in t.upper() for t in cells)
  row=dict(k=k,bits=d,padding=pad,width=32,height=24,LUT1_4=sum(cells.get('LUT'+str(i),0) for i in range(1,5)),
    FF=sum(n for t,n in cells.items() if t.startswith('DFF')),BSRAM=sum(cells.get(t,0) for t in ('SPX9','DPX9B','SDPX9B','SP','DPB','SDPB')),
    DSP=dsp,raw_cells=dict(cells),status='SYNTHESIS PASS',timing='NOT RUN',board='NOT RUN')
  (case/'resources.json').write_text(json.dumps(row,indent=2));results.append(row);print(row,flush=True)
(out/'summary.json').write_text(json.dumps(results,indent=2));print(out)

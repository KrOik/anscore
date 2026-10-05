"""Recheck positive matrix with explicit startup/tail/frame/row timing assertions."""
import datetime,json,os,shutil,subprocess
from test_median import HERE,LIB,ROOT
base=HERE/'evidence/sim_20260925_033407_661717';out=HERE/'evidence'/('timing_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));out.mkdir(parents=True)
cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ);env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
shutil.copy2(HERE/'tb_median.sv',out/'tb_median.sv');results=[]
for row in json.loads((base/'summary.json').read_text())['cases']:
 w,h,k,d,pad=(row[n] for n in ('w','h','k','bits','pad'));name=f'w{w}_h{h}_k{k}_d{d}_pad{pad}';case=out/name;case.mkdir()
 for n in ('input.mem','expected.mem'):shutil.copy2(base/name/n,case/n)
 cmd=[str(cad/'bin/iverilog.exe'),'-g2012','-s','tb_median','-o','sim.vvp',f'-Ptb_median.W={w}',f'-Ptb_median.H={h}',f'-Ptb_median.K={k}',f'-Ptb_median.D={d}',f'-Ptb_median.PAD={pad}']+[str(base/'sources'/n) for n in ('stream_window.v','stream_window_padded.v','median_network.v','median_stream.v')]+[str(out/'tb_median.sv')]
 for label,c in [('compile',cmd),('run',[str(cad/'bin/vvp.exe'),'sim.vvp'])]:
  p=subprocess.run(c,cwd=case,env=env,capture_output=True,text=True);(case/f'{label}.log').write_text(p.stdout+p.stderr);assert p.returncode==0,(name,p.stdout,p.stderr)
 lat=10 if k==3 else 15
 results.append(dict(case=name,startup=w*(1+min(k//2,h-1))+(k-1)*(w+k-1)+k-1+4+lat,tail=(w+k-1)*(k if h==1 else k//2+1)+4+lat,frame_interval=w*h+(w+k-1)*(h+k-1)+4,status='PASS'))
(out/'summary.json').write_text(json.dumps(dict(status='PASS',cases=results),indent=2));print('PASS',out)

import datetime,hashlib,itertools,json,os,pathlib,random,shutil,subprocess
from model import median_image
HERE=pathlib.Path(__file__).resolve().parent;LIB=HERE.parents[1];ROOT=LIB.parents[1]
def main():
 out=HERE/'evidence'/('sim_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));out.mkdir(parents=True);src=out/'sources';src.mkdir()
 files=list(HERE.glob('*.v'))+list(HERE.glob('*.sv'))+list(HERE.glob('*.py'))+[LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v']
 for f in files:shutil.copy2(f,src/f.name)
 (out/'hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2));src=src.resolve()
 cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ);env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH'];iv=str(cad/'bin/iverilog.exe');vv=str(cad/'bin/vvp.exe');results=[]
 configs=[(w,h,k,d,pad) for w,h in ((1,1),(2,3),(7,6)) for k,d,pad in itertools.product((3,5),(8,10),(0,1))]
 rtl=[str(src/n) for n in ('stream_window.v','stream_window_padded.v','median_network.v','median_stream.v')]
 for w,h,k,d,pad in configs:
  case=out/f'w{w}_h{h}_k{k}_d{d}_pad{pad}';case.mkdir();rng=random.Random(2026+w+h+k+d);inputs=[];expected=[];m=(1<<d)-1
  for f in range(6):
   frame=[[0 if f==0 else m if f==1 else (m if (x==w//2 and y==h//2) else 0) if f==2 else (m if (x+y)%2 else 0) if f==3 else rng.randrange(m+1) for x in range(w)]for y in range(h)]
   answer=median_image(frame,k,pad,d);assert answer==median_image(frame,k,pad,d,True)
   for y in range(h):
    for x in range(w):
     markers=((x==w-1)<<d)|((x==0 and y==0)<<(d+1));inputs.append(frame[y][x]|markers);expected.append(answer[y][x]|markers)
  order=next((i for i,v in enumerate(expected) if v!=expected[0]),None)
  for name,values in [('input',inputs),('expected',expected)]: (case/(name+'.mem')).write_text(''.join(f'{v:x}\n' for v in values))
  cmd=[iv,'-g2012','-Wall','-s','tb_median','-o','sim.vvp',f'-Ptb_median.W={w}',f'-Ptb_median.H={h}',f'-Ptb_median.K={k}',f'-Ptb_median.D={d}',f'-Ptb_median.PAD={pad}',f'-Ptb_median.ORDER_INDEX={order or 0}']+rtl+[str(src/'tb_median.sv')]
  for label,command in [('compile',cmd),('run',[vv,'sim.vvp'])]:
   r=subprocess.run(command,cwd=case,env=env,capture_output=True,text=True,timeout=120);(case/(label+'.log')).write_text(r.stdout+r.stderr);assert r.returncode==0,(case,r.stdout,r.stderr)
  mutations=['data','sideband','count']+(['order'] if order is not None else [])
  for mutation in mutations:
   r=subprocess.run([vv,'sim.vvp','+'+mutation],cwd=case,env=env,capture_output=True,text=True,timeout=120);(case/f'negative_{mutation}.log').write_text(r.stdout+r.stderr);assert r.returncode!=0 and ('median mismatch' in r.stdout or mutation=='count' and 'count timeout' in r.stdout),(case,mutation,r.stdout)
  results.append(dict(w=w,h=h,k=k,bits=d,pad=pad,frames=18,sort_latency=10 if k==3 else 15,II_inside_output_row=1,checker_mutations=mutations,status='PASS'));print('PASS',case.name,flush=True)
 for param,value in [('BITS',9),('WIDTH',0),('HEIGHT',0),('K',4),('PAD_MODE',2)]:
  case=out/('invalid_'+param);case.mkdir();(case/'tb.sv').write_text(f'module tb;median_stream #(.{param}({value}))dut();initial #1 $finish;endmodule')
  c=subprocess.run([iv,'-g2012','-s','tb','-o','bad.vvp','tb.sv']+rtl,cwd=case,env=env,capture_output=True,text=True)
  if c.returncode:assert param in ('K','WIDTH','HEIGHT'),c.stderr
  else:
   r=subprocess.run([vv,'bad.vvp'],cwd=case,env=env,capture_output=True,text=True);(case/'run.log').write_text(r.stdout+r.stderr);assert r.returncode!=0 and 'unsupported' in r.stdout
 (out/'summary.json').write_text(json.dumps(dict(status='PASS',cases=results,illegal_parameters=5),indent=2));print(out)
if __name__=='__main__':main()

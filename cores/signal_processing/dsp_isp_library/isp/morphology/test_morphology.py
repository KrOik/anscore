"""Snapshot sources, generate independent frames, execute real RTL regression."""
import argparse,datetime,hashlib,json,os,pathlib,random,shutil,subprocess
from model import morphology,stage
HERE=pathlib.Path(__file__).resolve().parent;LIB=HERE.parents[1];ROOT=LIB.parents[1]

def main():
 assert stage([[10,20,30]],3,1<<5,False,1)==[[20,30,30]]
 assert stage([[10,20,30]],3,1<<5,True,1)==[[10,10,20]]
 try:morphology([[1]],3,0,0)
 except ValueError:pass
 else:raise AssertionError('model accepted empty mask')
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path);a=p.parse_args()
 out=a.output or HERE/'evidence'/('sim_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
 out.mkdir(parents=True,exist_ok=False);src=out/'sources';src.mkdir()
 files=list(HERE.glob('*.v'))+list(HERE.glob('*.sv'))+list(HERE.glob('*.py'))+[LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v']
 for f in files:shutil.copy2(f,src/f.name)
 (out/'hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
 src=src.resolve();cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ)
 env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
 iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH'])
 results=[]
 configs=[(1,1,3,8),(2,2,5,10),(3,3,3,10),(7,6,3,8),(5,5,5,8),(9,8,5,10)]
 for w,h,k,d,pad in [(*c,p) for c in configs for p in (0,1)]:
   case=out/f'w{w}_h{h}_k{k}_d{d}_pad{pad}';case.mkdir()
   rng=random.Random(910+w+h+k+d);maskset=[(1<<(k*k))-1,1<<((k*k)//2),sum(1<<(y*k+x) for y in range(k) for x in range(k) if x==k//2 or y==k//2),1|(1<<(k*k-2))]
   inputs=[];expected=[];cfg=[]
   for op in range(4):
    for binary in (0,1):
     for mi,mask in enumerate(maskset):
      # Zero/maximum/impulse/random values and deliberately asymmetric support.
      frame=[[rng.randrange(1<<d) if mi==3 else (0 if mi==0 else ((1<<d)-1 if mi==1 or x==w//2 and y==h//2 else 0)) for x in range(w)] for y in range(h)]
      answer=morphology(frame,k,mask,op,bool(binary),pad)
      cfg.append((mask<<3)|(binary<<2)|op)
      for y in range(h):
       for x in range(w):
        markers=((x==w-1)<<d)|((x==0 and y==0)<<(d+1))
        inputs.append(frame[y][x]|markers);expected.append(answer[y][x]|markers)
   for name,data in [('input',inputs),('expected',expected),('config',cfg)]:
    (case/(name+'.mem')).write_text(''.join(f'{v:x}\n' for v in data))
   cmd=[iv,'-g2012','-Wall','-s','tb_morphology','-o','sim.vvp',f'-Ptb_morphology.W={w}',f'-Ptb_morphology.H={h}',f'-Ptb_morphology.K={k}',f'-Ptb_morphology.D={d}',f'-Ptb_morphology.PAD={pad}']+[str(src/n) for n in ('stream_window.v','stream_window_padded.v','morph_reduce.v','morphology_stream.v','tb_morphology.sv')]
   for label,command in [('compile',cmd),('run',[vv,'sim.vvp'])]:
    r=subprocess.run(command,cwd=case,env=env,capture_output=True,text=True,timeout=120)
    (case/(label+'.log')).write_text('$ '+' '.join(command)+'\n'+r.stdout+r.stderr)
    assert r.returncode==0,(case,r.stdout,r.stderr)
   for mutation in ('data','sideband','count','order'):
    r=subprocess.run([vv,'sim.vvp','+'+mutation],cwd=case,env=env,capture_output=True,text=True,timeout=120)
    (case/('negative_'+mutation+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode!=0 and ('morph mismatch' in r.stdout or mutation=='count' and 'count timeout' in r.stdout),(case,mutation,r.stdout)
   results.append(dict(w=w,h=h,k=k,bits=d,padding=pad,frames=96,status='PASS',checker_negatives=4));print('PASS',case.name,flush=True)
 for param,value in [('BITS',9),('WIDTH',0),('HEIGHT',0),('K',4),('PAD_MODE',2)]:
   case=out/('invalid_'+param);case.mkdir()
   (case/'tb.sv').write_text(f'module tb; morphology_stream #(.{param}({value})) dut(); initial #1 $finish; endmodule\n')
   cmd=[iv,'-g2012','-s','tb','-o','bad.vvp','tb.sv']+[str(src/n) for n in ('stream_window.v','stream_window_padded.v','morph_reduce.v','morphology_stream.v')]
   cp=subprocess.run(cmd,cwd=case,env=env,capture_output=True,text=True)
   assert cp.returncode==0,cp.stderr
   rp=subprocess.run([vv,'bad.vvp'],cwd=case,env=env,capture_output=True,text=True)
   (case/'run.log').write_text(cp.stdout+cp.stderr+rp.stdout+rp.stderr)
   assert rp.returncode!=0 and 'unsupported' in rp.stdout
 (out/'summary.json').write_text(json.dumps(dict(cases=results,illegal_static_parameters=5,model_reflection_tests='PASS'),indent=2));print(out)
if __name__=='__main__':main()

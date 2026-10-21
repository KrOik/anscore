"""Float-angle/exact-integer reference versus real RTL under frame config stress."""
import datetime,hashlib,json,os,pathlib,random,shutil,subprocess,math
from model import gradients,pack,direction
HERE=pathlib.Path(__file__).resolve().parent;LIB=HERE.parents[1];ROOT=LIB.parents[1]
def main():
 out=HERE/'evidence'/('sim_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));out.mkdir(parents=True)
 src=out/'sources';src.mkdir();files=list(HERE.glob('*.v'))+list(HERE.glob('*.sv'))+list(HERE.glob('*.py'))+[LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v']
 for f in files:shutil.copy2(f,src/f.name)
 (out/'hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
 src=src.resolve();cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ);env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
 iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);results=[]
 for w,h,d,pad in [(*c,p) for c in [(1,1,8),(2,2,10),(3,3,8),(7,6,10),(9,8,8)] for p in (0,1)]:
   case=out/f'w{w}_h{h}_d{d}_pad{pad}';case.mkdir();rng=random.Random(417+w+h+d);g=d+5;ow=3*g+5;maxpix=(1<<d)-1
   inputs=[];expected=[];cfg=[];maxangle=maxmag=0
   for f in range(16):
    scharr=bool(f&1);l1=bool((f>>1)&1);threshold=[0,1,4*maxpix,(1<<g)-1][f//4]
    pattern=(f+f//4)%8
    frame=[[rng.randrange(1<<d) if pattern==0 else (maxpix if pattern==1 else (0 if pattern==2 else (maxpix if (pattern==3 and x>=w//2) or (pattern==4 and y>=h//2) or (pattern==5 and (x+y)%2==0) or (pattern==6 and x==w//2 and y==h//2) else ((x+2*y)*maxpix//max(1,w+2*h-3) if pattern==7 else 0)))) for x in range(w)] for y in range(h)]
    ans=gradients(frame,scharr,l1,threshold,pad);cfg.append((threshold<<2)|(int(l1)<<1)|int(scharr))
    for y in range(h):
     for x in range(w):
      v=ans[y][x];maxangle=max(maxangle,v['direction_error_deg']);maxmag=max(maxmag,v['float_magnitude']-v['magnitude'])
      inputs.append(frame[y][x]|((x==w-1)<<d)|((x==0 and y==0)<<(d+1)))
      expected.append(pack(v,d)|((x==w-1)<<ow)|((x==0 and y==0)<<(ow+1)))
   assert maxangle<22.52 and maxmag<1
   for name,data in [('input',inputs),('expected',expected),('config',cfg)]:
    (case/(name+'.mem')).write_text(''.join(f'{v:x}\n' for v in data))
   cmd=[iv,'-g2012','-Wall','-s','tb_gradient','-o','sim.vvp',f'-Ptb_gradient.W={w}',f'-Ptb_gradient.H={h}',f'-Ptb_gradient.D={d}',f'-Ptb_gradient.PAD={pad}']+[str(src/n) for n in ('stream_window.v','stream_window_padded.v','gradient_stream.v','tb_gradient.sv')]
   for label,command in [('compile',cmd),('run',[vv,'sim.vvp'])]:
    r=subprocess.run(command,cwd=case,env=env,capture_output=True,text=True,timeout=120);(case/(label+'.log')).write_text(r.stdout+r.stderr);assert r.returncode==0,(case,r.stdout,r.stderr)
   for mutation in ('data','sideband','count','order'):
    r=subprocess.run([vv,'sim.vvp','+'+mutation],cwd=case,env=env,capture_output=True,text=True,timeout=120);(case/('negative_'+mutation+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode!=0 and ('gradient mismatch' in r.stdout or mutation=='count' and 'count timeout' in r.stdout),(case,mutation,r.stdout)
   results.append(dict(w=w,h=h,bits=d,padding=pad,frames=51,max_angle_error_deg=maxangle,max_magnitude_floor_error=maxmag,status='PASS'));print('PASS',case.name,flush=True)
 for param,value in [('BITS',9),('WIDTH',0),('HEIGHT',0),('PAD_MODE',2)]:
   case=out/('invalid_'+param);case.mkdir();(case/'tb.sv').write_text(f'module tb; gradient_stream #(.{param}({value})) dut(); initial #1 $finish; endmodule\n')
   cmd=[iv,'-g2012','-s','tb','-o','bad.vvp','tb.sv']+[str(src/n) for n in ('stream_window.v','stream_window_padded.v','gradient_stream.v')]
   cp=subprocess.run(cmd,cwd=case,env=env,capture_output=True,text=True);assert cp.returncode==0,cp.stderr
   rp=subprocess.run([vv,'bad.vvp'],cwd=case,env=env,capture_output=True,text=True);(case/'run.log').write_text(cp.stdout+cp.stderr+rp.stdout+rp.stderr);assert rp.returncode!=0 and 'unsupported' in rp.stdout
 (out/'summary.json').write_text(json.dumps(dict(cases=results,illegal_static_parameters=4,negative_runs=40),indent=2));print(out)
if __name__=='__main__':main()

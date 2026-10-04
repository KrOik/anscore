"""Independent exact/float vectors and real Stream simulation."""
import datetime,hashlib,json,os,pathlib,random,shutil,subprocess
from model import convolve,round_even
HERE=pathlib.Path(__file__).resolve().parent;LIB=HERE.parents[1];ROOT=LIB.parents[1]

def main():
 assert [round_even(x,1) for x in (1,3,5,-1,-3,-5)]==[0,2,2,0,-2,-2]
 out=HERE/'evidence'/('sim_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));out.mkdir(parents=True)
 src=out/'sources';src.mkdir();files=list(HERE.glob('*.v'))+list(HERE.glob('*.sv'))+list(HERE.glob('*.py'))+[LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v']
 for f in files:shutil.copy2(f,src/f.name)
 (out/'hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
 src=src.resolve();cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ)
 env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
 iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);results=[]
 for w,h,k,d,pad in [(*c,p) for c in [(1,1,3,8),(2,2,5,10),(3,3,3,10),(7,6,3,8),(5,5,5,8),(9,8,5,10)] for p in (0,1)]:
   case=out/f'w{w}_h{h}_k{k}_d{d}_pad{pad}';case.mkdir();rng=random.Random(745+w+h+k+d);n=k*k
   center=[int(i==n//2) for i in range(n)]
   sharpen=[-1]*n;sharpen[n//2]=n
   asym=[0]*n;asym[n//2+1]=1
   settings=[(center,0,0),([1]*n,0,5),(sharpen,0,0),(asym,0,0),
             ([-2048]*n,0,0),([2047]*n,0,7),([0]*n,2147483647,0),([0]*n,-2147483648,0),
             ([0]*n,1,1),([0]*n,3,1),([0]*n,5,1),([0]*n,-3,1),
             (center,0,31),(center,127,3),([rng.randrange(-2048,2048) for _ in range(n)],65535,11),
             ([rng.randrange(-10,11) for _ in range(n)],-71,3)]
   inputs=[];expected=[];cfg=[];maxerror=0.0
   for f,(coeff,bias,shift) in enumerate(settings):
    frame=[[rng.randrange(1<<d) if f%4==0 else (0 if f%4==1 else ((1<<d)-1 if f%4==2 or x==w//2 and y==h//2 else 0)) for x in range(w)] for y in range(h)]
    if f==1:frame=[[(x+3*y+1)% (1<<d) for x in range(w)] for y in range(h)]
    if f in (4,5):frame=[[(1<<d)-1]*w for _ in range(h)]
    exact=convolve(frame,k,coeff,bias,shift,d,pad);floating=convolve(frame,k,coeff,bias,shift,d,pad,True)
    maxerror=max(maxerror,max(abs(exact[y][x]-floating[y][x]) for y in range(h) for x in range(w)))
    coeffword=sum((c&4095)<<(12*i) for i,c in enumerate(coeff));cfg.append((coeffword<<38)|((bias&0xffffffff)<<6)|shift)
    for y in range(h):
     for x in range(w):
      flags=((x==w-1)<<d)|((x==0 and y==0)<<(d+1));inputs.append(frame[y][x]|flags);expected.append(exact[y][x]|flags)
   assert maxerror<=.5
   for name,data in [('input',inputs),('expected',expected),('config',cfg)]:
    (case/(name+'.mem')).write_text(''.join(f'{v:x}\n' for v in data))
   cmd=[iv,'-g2012','-Wall','-s','tb_convolution','-o','sim.vvp',f'-Ptb_convolution.W={w}',f'-Ptb_convolution.H={h}',f'-Ptb_convolution.K={k}',f'-Ptb_convolution.D={d}',f'-Ptb_convolution.PAD={pad}']+[str(src/n) for n in ('stream_window.v','stream_window_padded.v','convolution_stream.v','tb_convolution.sv')]
   for label,command in [('compile',cmd),('run',[vv,'sim.vvp'])]:
    r=subprocess.run(command,cwd=case,env=env,capture_output=True,text=True,timeout=120)
    (case/(label+'.log')).write_text('$ '+' '.join(command)+'\n'+r.stdout+r.stderr);assert r.returncode==0,(case,r.stdout,r.stderr)
   for mutation in ('data','sideband','count','order'):
    r=subprocess.run([vv,'sim.vvp','+'+mutation],cwd=case,env=env,capture_output=True,text=True,timeout=120)
    (case/('negative_'+mutation+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode!=0 and ('convolution mismatch' in r.stdout or mutation=='count' and 'count timeout' in r.stdout),(case,mutation,r.stdout)
   results.append(dict(w=w,h=h,k=k,bits=d,padding=pad,frames=51,float_max_abs_error=maxerror,status='PASS'));print('PASS',case.name,flush=True)
 for param,value in [('BITS',9),('WIDTH',0),('HEIGHT',0),('K',4),('PAD_MODE',2)]:
   case=out/('invalid_'+param);case.mkdir();(case/'tb.sv').write_text(f'module tb; convolution_stream #(.{param}({value})) dut(); initial #1 $finish; endmodule\n')
   cmd=[iv,'-g2012','-s','tb','-o','bad.vvp','tb.sv']+[str(src/n) for n in ('stream_window.v','stream_window_padded.v','convolution_stream.v')]
   cp=subprocess.run(cmd,cwd=case,env=env,capture_output=True,text=True);assert cp.returncode==0,cp.stderr
   rp=subprocess.run([vv,'bad.vvp'],cwd=case,env=env,capture_output=True,text=True);(case/'run.log').write_text(cp.stdout+cp.stderr+rp.stdout+rp.stderr)
   assert rp.returncode!=0 and 'unsupported' in rp.stdout
 (out/'summary.json').write_text(json.dumps(dict(cases=results,illegal_static_parameters=5,checker_negative_runs=48),indent=2));print(out)
if __name__=='__main__':main()

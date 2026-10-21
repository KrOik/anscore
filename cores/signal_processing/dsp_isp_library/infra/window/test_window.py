"""Independent raster slicing oracle, randomized protocol RTL regression."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
from model import windows

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
    sources=a.output/'sources';sources.mkdir()
    hashes={}
    for source in HERE.iterdir():
        if source.suffix in ('.v','.sv','.py'):
            shutil.copy2(source,sources/source.name)
            hashes[source.name]=hashlib.sha256(source.read_bytes()).hexdigest()
    (a.output/'source_sha256.json').write_text(json.dumps(hashes,indent=2))
    sources=sources.resolve()
    tool=ROOT/'tools/oss-cad-suite/oss-cad-suite'
    env=dict(os.environ)
    env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
    results=[]
    configs=[(1,1,3,8),(2,4,3,10),(3,3,3,8),(7,6,3,10),
             (1,1,5,10),(2,3,5,8),(5,5,5,8),(9,8,5,10),(32,24,3,8),(32,24,5,10)]
    for w,h,k,d,pad in [(*c,p) for p in (-1,0,1) for c in configs]:
        out=a.output/f'w{w}_h{h}_k{k}_d{d}_pad{pad}';out.mkdir()
        rng=random.Random(1949+w+h+k+d)
        inputs=[];expected=[]
        for f in range(3):
            frame=[[rng.randrange(1<<d) for x in range(w)] for y in range(h)]
            for y in range(h):
                for x in range(w):
                    inputs.append(frame[y][x] | ((x==w-1)<<d) | ((x==0 and y==0)<<(d+1)))
            for pixels,eol,sof in windows(frame,k,pad):
                word=sum(v<<(i*d) for i,v in enumerate(pixels))
                word|=eol<<(k*k*d);word|=sof<<(k*k*d+1)
                expected.append(word)
        (out/'input.mem').write_text(''.join(f'{x:x}\n' for x in inputs))
        (out/'expected.mem').write_text(''.join(f'{x:x}\n' for x in expected))
        cmds=[['iverilog','-g2012','-s','tb_stream_window','-o','sim.vvp',
               f'-Ptb_stream_window.W={w}',f'-Ptb_stream_window.H={h}',
               f'-Ptb_stream_window.K={k}',f'-Ptb_stream_window.D={d}',
               f'-Ptb_stream_window.PAD={pad}',
               str(sources/'stream_window.v'),str(sources/'stream_window_padded.v'),str(sources/'tb_stream_window.sv')],['vvp','sim.vvp']]
        for i,cmd in enumerate(cmds):
            cmd[0]=shutil.which(cmd[0],path=env['PATH']) or cmd[0]
            r=subprocess.run(cmd,cwd=out,env=env,text=True,capture_output=True,timeout=90)
            (out/f'{i}.log').write_text(r.stdout+r.stderr)
            if r.returncode: raise RuntimeError(f'FAIL {out}: {r.stdout}{r.stderr}')
        if expected:
            for mutation in ('mutate','order','count','sideband'):
                r=subprocess.run([cmds[1][0],'sim.vvp','+'+mutation],cwd=out,env=env,text=True,capture_output=True,timeout=90)
                (out/f'mutation_{mutation}.log').write_text(r.stdout+r.stderr)
                assert r.returncode!=0 and ('window mismatch' in r.stdout or mutation=='count' and 'timeout' in r.stdout)
        results.append(dict(w=w,h=h,k=k,d=d,padding=pad,outputs=len(expected),passed=True))
        print(f'PASS {out.name}; payload/order/count/sideband negative checks'+(' passed' if expected else ' N/A (empty)'))
    for module,parameter,value in [('stream_window','K',4),('stream_window','WIDTH',0),
                                  ('stream_window','HEIGHT',0),('stream_window','DATA_WIDTH',17),
                                  ('stream_window_padded','PAD_MODE',2),('stream_window_padded','MAX_WIDTH',1)]:
        out=a.output/f'invalid_{module}_{parameter}';out.mkdir()
        (out/'tb.sv').write_text(f'module tb; {module} #(.{parameter}({value})) dut(); initial #1 $finish; endmodule\n')
        cp=subprocess.run([cmds[0][0],'-g2012','-s','tb','-o','sim.vvp',str(sources/'stream_window.v'),str(sources/'stream_window_padded.v'),'tb.sv'],cwd=out,env=env,capture_output=True,text=True)
        assert cp.returncode==0,cp.stderr
        rp=subprocess.run([cmds[1][0],'sim.vvp'],cwd=out,env=env,capture_output=True,text=True)
        (out/'run.log').write_text(cp.stdout+cp.stderr+rp.stdout+rp.stderr)
        assert rp.returncode!=0 and 'unsupported' in rp.stdout
    (a.output/'results.json').write_text(json.dumps(results,indent=2)+'\n')

if __name__=='__main__':main()

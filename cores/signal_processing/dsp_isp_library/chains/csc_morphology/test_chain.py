"""Queued config, reset, stall and independent composed-model chain regression."""
import argparse,datetime,hashlib,json,os,pathlib,shutil,subprocess,sys
HERE=pathlib.Path(__file__).resolve().parent;LIB=HERE.parents[1];ROOT=LIB.parents[1]
sys.path.insert(0,str(LIB/'board/image_harness'))
from protocol import cases,oracle
def main():
 p=argparse.ArgumentParser();p.add_argument('--window-source');p.add_argument('--padded-source');a=p.parse_args()
 out=HERE/'evidence'/datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f');out.mkdir(parents=True);src=out/'sources';src.mkdir()
 files=[HERE/'csc_morphology_stream.v',HERE/'tb_chain.sv',LIB/'isp/csc_stream.v',LIB/'isp/csc_coeffs.vh',LIB/'isp/morphology/morphology_stream.v',LIB/'isp/morphology/morph_reduce.v',LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v']
 files=[pathlib.Path(a.window_source) if f.name=='stream_window.v' and a.window_source else pathlib.Path(a.padded_source) if f.name=='stream_window_padded.v' and a.padded_source else f for f in files]
 if a.window_source or a.padded_source:files.append(ROOT/'cores/image_processing/window/sim/gowin_bsram_sim.v')
 for f in files:shutil.copy2(f,src/f.name)
 (out/'hashes.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
 src=src.resolve();cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ);env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH'];rows=[]
 for bits in (8,10):
  for pad in (0,1):
   work=out/f'bits{bits}_pad{pad}';work.mkdir();inputs=[];expected=[];configs=[]
   for _,c,words,_ in cases(bits):
    configs.append(c);answer=oracle(bits,c,words,pad)
    for i,w in enumerate(words):
     inputs.append(w|((i%8==7)<<(3*bits))|((i==0)<<(3*bits+1)))
     expected.append((answer[i]&((1<<bits)-1))|((i%8==7)<<bits)|((i==0)<<(bits+1)))
   for name,data in [('input',inputs),('expected',expected),('config',configs)]:
    (work/(name+'.mem')).write_text(''.join(f'{v:x}\n' for v in data))
   cmd=[shutil.which('iverilog',path=env['PATH']),'-g2012','-Wall','-I'+str(src),'-s','tb_chain',f'-Ptb_chain.D={bits}',f'-Ptb_chain.PAD={pad}','-o','sim.vvp']+[str(src/f.name) for f in files if f.suffix in ('.v','.sv')]
   for label,command in [('compile',cmd),('run',[shutil.which('vvp',path=env['PATH']),'sim.vvp'])]:
    r=subprocess.run(command,cwd=work,env=env,capture_output=True,text=True);(work/(label+'.log')).write_text(r.stdout+r.stderr);assert r.returncode==0,(work,r.stdout,r.stderr)
   for mutation in ('data','sideband','count','order'):
    r=subprocess.run([shutil.which('vvp',path=env['PATH']),'sim.vvp','+'+mutation],cwd=work,env=env,capture_output=True,text=True);(work/('negative_'+mutation+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode!=0 and ('chain mismatch' in r.stdout or mutation=='count' and 'count timeout' in r.stdout),(work,mutation,r.stdout)
   rows.append(dict(bits=bits,padding=pad,frames=48,status='PASS'));print('PASS',work,flush=True)
 (out/'summary.json').write_text(json.dumps(rows,indent=2))
if __name__=='__main__':main()

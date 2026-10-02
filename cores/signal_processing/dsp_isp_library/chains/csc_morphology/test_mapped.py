"""Map the explicit RAM candidate, then rerun the independent chain scoreboard."""
import argparse,datetime,hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;LIB=HERE.parents[1];ROOT=LIB.parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--window-source',type=Path);p.add_argument('--bits',type=int,choices=(8,10),default=8);p.add_argument('--replay-json',type=Path);a=p.parse_args()
 out=HERE/'evidence'/('mapped_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));out.mkdir(parents=True)
 prior=HERE/'evidence/20260925_040754_339321'
 for f in (prior/'sources').iterdir():shutil.copy2(f,out/f.name)
 if a.window_source:shutil.copy2(a.window_source,out/'stream_window.v')
 for f in (prior/f'bits{a.bits}_pad1').glob('*.mem'):shutil.copy2(f,out/f.name)
 if a.replay_json:
  sys.path.insert(0,str(LIB/'board/image_harness'));from protocol import oracle
  v=json.loads(a.replay_json.read_text());assert v['bits']==a.bits and v['padding']==1
  answers=oracle(a.bits,v['config'],v['words'],1)
  inputs=[w|((i%8==7)<<(3*a.bits))|((i==0)<<(3*a.bits+1)) for i,w in enumerate(v['words'])]
  expected=[(w&((1<<a.bits)-1))|((i%8==7)<<a.bits)|((i==0)<<(a.bits+1)) for i,w in enumerate(answers)]
  for name,values in [('input',inputs),('expected',expected),('config',[v['config']])]:
   path=out/(name+'.mem');lines=path.read_text().splitlines();lines[:len(values)]=[f'{x:x}' for x in values];path.write_text('\n'.join(lines)+'\n')
  shutil.copy2(a.replay_json,out/'replayed_input.json')
 (out/'hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in out.iterdir() if f.is_file()},indent=2))
 cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ);env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
 def run(cmd,log):
  cmd=[shutil.which(cmd[0],path=env['PATH']) or cmd[0],*cmd[1:]]
  with (out/log).open('w') as fp:r=subprocess.run(cmd,cwd=out,env=env,stdout=fp,stderr=subprocess.STDOUT)
  assert r.returncode==0,(out,log)
 rtl=['csc_morphology_stream.v','csc_stream.v','morphology_stream.v','morph_reduce.v','stream_window.v','stream_window_padded.v']
 (out/'map.ys').write_text('read_verilog -sv -I. '+' '.join(rtl)+f'\nchparam -set BITS {a.bits} -set WIDTH 8 -set HEIGHT 8 -set PAD_MODE 1 csc_morphology_stream\nsynth_gowin -noalu -family gw2a -top csc_morphology_stream\nwrite_verilog -noattr mapped.v\n')
 run(['yosys','-s','map.ys'],'synthesis.log')
 tb=(out/'tb_chain.sv').read_text().replace('csc_morphology_stream #(.BITS(D),.WIDTH(W),.HEIGHT(H),.PAD_MODE(PAD)) dut(','csc_morphology_stream dut(')
 (out/'tb_chain_mapped.sv').write_text(tb)
 cells=cad/'share/yosys/gowin/cells_sim.v'
 run(['iverilog','-g2012','-s','tb_chain',f'-Ptb_chain.D={a.bits}','-o','mapped.vvp','tb_chain_mapped.sv','mapped.v','gowin_bsram_sim.v',str(cells)],'compile.log')
 run(['vvp','mapped.vvp'],'simulation.log')
 (out/'summary.json').write_text(json.dumps(dict(status='PASS',bits=a.bits,padding=1,frames=48,limitation='Zero-delay mapped logic plus measured width-18 primitive model; not silicon timing proof.'),indent=2));print('MAPPED PASS',out,flush=True)
if __name__=='__main__':main()

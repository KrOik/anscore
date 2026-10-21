from pathlib import Path
import sys,tempfile,json,hashlib
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[4];SV=COMMON/'signal_video';DSP=COMMON/'dsp'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(SV));sys.path.insert(0,str(DSP))
from tooling import execute
from cic_adapter_reference import fixtures

def main():
 results=[]
 with tempfile.TemporaryDirectory(prefix='cic_candidate_') as temporary:
  t=Path(temporary)
  for rate,stages,width in [(1,1,8),(2,2,10),(8,3,17),(5,4,20),(3,3,14)]:
   label=f'core_r{rate}_s{stages}_w{width}';binary=t/(label+'.vvp')
   execute(['iverilog','-g2012','-s','tb_cic_pipeline',f'-Ptb_cic_pipeline.RATE={rate}',f'-Ptb_cic_pipeline.STAGES={stages}',f'-Ptb_cic_pipeline.ACC_W={width}','-o',binary,HERE/'cip_dsp_cic_decimator.v',HERE/'tb_cic_pipeline.v'],HERE,HERE/(label+'_compile.log'))
   result=execute(['vvp',binary],HERE,HERE/(label+'_simulation.log'));assert 'CIC_PIPELINE PASS' in result;print(result.strip());results.append({'kind':'core','rate':rate,'stages':stages,'width':width})
  for rate,stages,shift in [(1,1,0),(8,3,9),(8,3,0),(3,2,1),(3,3,4)]:
   label=f'adapter_r{rate}_s{stages}_shift{shift}';f=t/label;f.mkdir();counts=fixtures(f,rate,stages,shift);binary=f/'sim.vvp'
   execute(['iverilog','-g2012','-s','tb_cip_cic_decimator',f'-Ptb_cip_cic_decimator.RATE={rate}',f'-Ptb_cip_cic_decimator.STAGES={stages}',f'-Ptb_cip_cic_decimator.SHIFT={shift}','-o',binary,HERE/'cip_dsp_cic_decimator.v',SV/'rtl/cip_cic_decimator.v',SV/'sim/tb_cip_cic_decimator.v'],HERE,HERE/(label+'_compile.log'))
   result=execute(['vvp',binary,f'+folder={f}'],HERE,HERE/(label+'_simulation.log'));assert 'CIC_ADAPTER PASS' in result;assert f"outputs={counts['outputs']}" in result;print(result.strip());results.append({'kind':'adapter','rate':rate,'stages':stages,'shift':shift,**counts})
 (HERE/'regression_summary.json').write_text(json.dumps({'status':'PASS','cases':results,'candidate_sha256':hashlib.sha256((HERE/'cip_dsp_cic_decimator.v').read_bytes()).hexdigest()},indent=2)+'\n')
if __name__=='__main__':main()


"""Run the unchanged public CIC packet oracle against the integrated pipeline."""
from pathlib import Path
import hashlib,sys,tempfile
HERE=Path(__file__).resolve().parent;SV=HERE.parent/'signal_video'
sys.path.insert(0,str(HERE.parent/'integration'));sys.path.insert(0,str(SV))
from tooling import evidence_dir,execute,write_json
from cic_adapter_reference import fixtures

def main():
 evidence=evidence_dir('cic_pipeline_public_integration');results=[]
 sources=[SV/'rtl/cip_cic_decimator.v',HERE/'rtl/cip_dsp_cic_decimator.v',SV/'sim/tb_cip_cic_decimator.v']
 tracked=[*sources,SV/'cic_adapter_reference.py',Path(__file__)]
 hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 with tempfile.TemporaryDirectory(prefix='cip_cic_public_') as temporary:
  for rate,stages,shift in [(1,1,0),(8,3,9),(8,3,0),(3,2,1)]:
   label=f'r{rate}_n{stages}_s{shift}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,rate,stages,shift);image=folder/'test.vvp'
   execute(['iverilog','-g2012','-s','tb_cip_cic_decimator',f'-Ptb_cip_cic_decimator.RATE={rate}',f'-Ptb_cip_cic_decimator.STAGES={stages}',f'-Ptb_cip_cic_decimator.SHIFT={shift}','-o',image,*sources],HERE,evidence/(label+'_compile.log'))
   output=execute(['vvp',image,f'+folder={folder}'],HERE,evidence/(label+'_simulation.log'))
   if ('CIC_ADAPTER PASS' not in output or f"outputs={counts['outputs']}" not in output or f"packets={counts['packets']} responses={counts['packets']+3}" not in output):raise RuntimeError('missing public CIC acceptance marker')
   print(output.strip());results.append({'rate':rate,'stages':stages,'shift':shift,**counts})
 if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed during tests')
 write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
 print('evidence='+str(evidence))
if __name__=='__main__':main()

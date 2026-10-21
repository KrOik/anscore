from pathlib import Path
import sys,tempfile,json,hashlib
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
sys.path.insert(0,str(ROOT/'signal_video'))
import run_guided_nlm_tests as ref
from tooling import execute,evidence_dir,write_json
def main():
 evidence=evidence_dir('nlm_serial_v8');cases=[]
 sources=[ROOT/'signal_video/rtl/cip_image_nlm_denoise.v',ROOT/'signal_video/sim/tb_cip_image_nlm_denoise.v',HERE/'candidate_v8/img_filter_nlm.v',HERE/'candidate_v8/img_filter_nlm_serial_engine.v',ROOT/'image/filters/rtl/img_filter_exp_weight.v']
 hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(ref.__file__)]}
 with tempfile.TemporaryDirectory(prefix='nlm_serial_v8_') as temporary:
  for bits,gray in [(1,1),(8,8),(24,8),(32,12),(4,8),(24,13)]:
   label=f'w{bits}_g{gray}';folder=Path(temporary)/label;folder.mkdir();counts=ref.fixtures(folder,bits,gray,False);binary=folder/'test.vvp';top='tb_cip_image_nlm_denoise'
   execute(['iverilog','-g2012','-s',top,f'-P{top}.DW={bits}',f'-P{top}.GB={gray}','-o',binary,*sources],ROOT,evidence/f'{label}_compile.log')
   output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}'],ROOT,evidence/f'{label}_simulation.log',timeout=120)
   if 'NLM_DENOISE PASS' not in output:raise RuntimeError(output)
   print(output.strip(),flush=True);cases.append(counts)
 if any(hashlib.sha256(Path(p).read_bytes()).hexdigest()!=h for p,h in hashes.items()):raise RuntimeError('source changed during test')
 write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'NOT_RUN','synthesis':'NOT_RUN'})
 print(evidence)
if __name__=='__main__':main()

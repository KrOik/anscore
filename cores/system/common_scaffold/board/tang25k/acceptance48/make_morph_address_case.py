"""Frozen candidate-only morphology single-read-port inference repair and replay."""
from pathlib import Path
import argparse,hashlib,json,shutil,tempfile,sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[2]/'integration'))
from tooling import execute

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('original',type=Path);ap.add_argument('output',type=Path);a=ap.parse_args()
 old=a.original.resolve();out=a.output.resolve()
 if out.exists():raise RuntimeError('new candidate directory required')
 status=json.loads((old/'build_status.json').read_text())
 if status['simulation']!='PASS':raise RuntimeError('original simulation is not PASS')
 for name,expected in status['source_sha256'].items():
  source=old/name
  if digest(source)!=expected:raise RuntimeError('original freeze changed: '+name)
  target=out/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
 info=json.loads((out/'case.json').read_text())
 module=out/'source/cip_image_morph_frame.v'
 text=module.read_text().replace('RESPONSE=7;','RESPONSE=7,MEM_READ=8;').replace('reg [2:0] state,operation;','reg [3:0] state;\nreg [2:0] operation;').replace('reg [AW-1:0] index;','reg [AW-1:0] index,read_address_q;').replace('if(state==READ && !read_scratch)raw_q<=raw[read_address];','if(state==MEM_READ && !read_scratch)raw_q<=raw[read_address_q];').replace('(state==READ && read_scratch)','(state==MEM_READ && read_scratch)').replace('state==STORE ? index : read_address','state==STORE ? index : read_address_q').replace('mask<=0;tap<=0;','read_address_q<=0;mask<=0;tap<=0;').replace('READ:state<=REDUCE;','READ:begin read_address_q<=read_address;state<=MEM_READ;end\n        MEM_READ:state<=REDUCE;')
 module.write_text(text)
 driver=out/'source/acceptance48_driver.v'
 driver.write_text(driver.read_text().replace('always @(posedge clk or negedge rst_n)','always @(posedge clk)'))

 sources=info['sources']
 with tempfile.TemporaryDirectory(prefix='a48_hist_mapping_') as tmp:
  for kind,case in info['verification_cases'].items():
   selected=[out/case['top_source'],*[out/n for n in sources if n!='source/acceptance48_top.v']]
   binary=Path(tmp)/(kind+'.vvp')
   execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*selected,out/case['testbench']],out,out/(kind+'_compile.log'))
   output=execute(['vvp',binary,'+golden='+str(out/case['expected_uart'])],out,out/(kind+'_simulation.log'),timeout=600)
   if 'ACCEPTANCE48 UART GOLDEN PASS' not in output:raise RuntimeError('missing PASS')
 regdir=out/'independent_regression';regdir.mkdir()
 sv=HERE.parents[2]/'signal_video'
 sys.path.insert(0,str(sv))
 from run_morph_frame_tests import fixtures
 bench=regdir/'tb_cip_image_morph_frame.v';shutil.copy2(sv/'sim'/bench.name,bench)
 results=[]
 with tempfile.TemporaryDirectory(prefix='a48_morph_reference_') as tmp:
  for bits,adapter in [(b,a) for a in [0,1] for b in [1,8,16,24,32]]:
   folder=Path(tmp)/f'w{bits}_a{adapter}';folder.mkdir();case=fixtures(folder,bits,adapter);binary=folder/'test.vvp';label=f'w{bits}_a{adapter}'
   execute(['iverilog','-g2012','-s','tb_cip_image_morph_frame',f'-Ptb_cip_image_morph_frame.DW={bits}',f'-Ptb_cip_image_morph_frame.ADAPTER={adapter}','-o',binary,module,out/'source/cip_image_morphology.v',bench],out,regdir/(label+'_compile.log'))
   output=execute(['vvp',binary,f'+folder={folder}',f'+commands={case["commands"]}',f'+pixels={case["pixels"]}'],out,regdir/(label+'_simulation.log'),timeout=600)
   if f'MORPH_FRAME PASS width={bits}' not in output:raise RuntimeError('reference fail')
   results.append(dict(case,adapter=adapter))
 (regdir/'summary.json').write_text(json.dumps({'status':'PASS','cases':results},indent=2)+'\n')
 hashes={name:digest(out/name) for name in status['source_sha256'] if name!='case.json'}
 info['source_sha256']=hashes.copy();info['mapping_change']='Single synchronous scratch read-port mux, registered address stage, and synchronous isolated harness driver reset; public RTL and goldens unchanged; ten independent profiles pass.'
 info['original_case']=str(old);info['original_build_status_sha256']=digest(old/'build_status.json')
 (out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=digest(out/'case.json')
 (out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n')
 print(json.dumps({'candidate':str(out),'simulation':'PASS','source_sha256':digest(module)}))
if __name__=='__main__':main()

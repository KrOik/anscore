"""Frozen candidate-only histogram single-port inference repair and replay."""
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
 module=out/'source/cip_image_histogram_frame.v';text=module.read_text()
 before="""    if(state==CLEAR)histogram[bin]<=0;
    if(s_valid && s_ready)begin raw[index]<=s_data;hist_q<=histogram[s_data];end
    if(state==UPDATE)histogram[pending_gray]<=hist_q+1;
    if(state==BIN_READ)hist_q<=histogram[bin];"""
 after="""    // One explicit synchronous read and one write port; FSM timing unchanged.
    if(s_valid && s_ready)raw[index]<=s_data;
    if((s_valid && s_ready) || state==BIN_READ)
        hist_q<=histogram[state==BIN_READ ? bin : s_data];
    if(state==CLEAR || state==UPDATE)
        histogram[state==CLEAR ? bin : pending_gray]<=state==CLEAR ? 32'd0 : hist_q+32'd1;"""
 if text.count(before)!=1:raise RuntimeError('unexpected original RAM structure')
 module.write_text(text.replace(before,after))
 sources=info['sources']
 with tempfile.TemporaryDirectory(prefix='a48_hist_mapping_') as tmp:
  for kind,case in info['verification_cases'].items():
   selected=[out/case['top_source'],*[out/n for n in sources if n!='source/acceptance48_top.v']]
   binary=Path(tmp)/(kind+'.vvp')
   execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*selected,out/case['testbench']],out,out/(kind+'_compile.log'))
   output=execute(['vvp',binary,'+golden='+str(out/case['expected_uart'])],out,out/(kind+'_simulation.log'),timeout=600)
   if 'ACCEPTANCE48 UART GOLDEN PASS' not in output:raise RuntimeError('missing PASS')
 hashes={name:digest(out/name) for name in status['source_sha256'] if name!='case.json'}
 info['source_sha256']=hashes.copy();info['mapping_change']='Explicit single synchronous histogram read/write port mux; unchanged FSM, vectors and UART golden.'
 info['original_case']=str(old);info['original_build_status_sha256']=digest(old/'build_status.json')
 (out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=digest(out/'case.json')
 (out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n')
 print(json.dumps({'candidate':str(out),'simulation':'PASS','source_sha256':digest(module)}))
if __name__=='__main__':main()

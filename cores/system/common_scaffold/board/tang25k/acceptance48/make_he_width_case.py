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
 if text.count(after)!=1:raise RuntimeError('single-port original required')
 text=text.replace('localparam AW=', 'localparam COUNT_W=$clog2(DEPTH+1)>0?$clog2(DEPTH+1):1;\nlocalparam AW=')
 text=text.replace('reg [31:0] pixels,cdf,cdf_min,numerator,denominator;', 'reg [COUNT_W-1:0] pixels,cdf,cdf_min,numerator,denominator;')
 text=text.replace('reg [31:0] hist_q;', 'reg [COUNT_W-1:0] hist_q;')
 text=text.replace('reg [31:0] histogram[0:255];','reg [COUNT_W-1:0] histogram[0:255];')
 text=text.replace('wire [31:0] next_cdf=', 'wire [COUNT_W-1:0] next_cdf=').replace('wire [31:0] effective_min=', 'wire [COUNT_W-1:0] effective_min=')
 text=text.replace('.COUNT_WIDTH(32)', '.COUNT_WIDTH(COUNT_W)')
 text=text.replace("32'd0 : hist_q+32'd1", "{COUNT_W{1'b0}} : hist_q+1'b1")
 module.write_text(text)
 # Run the unmodified independent engine/adapter regression against this core.
 sv=HERE.parents[2]/'signal_video';sys.path.insert(0,str(sv))
 import run_histogram_frame_tests as independent
 regdir=out/'independent_regression';regdir.mkdir()
 tests=[sv/'sim/tb_cip_image_histogram_frame.v',sv/'rtl/cip_image_histogram.v',sv/'rtl/cip_image_he.v',HERE.parents[2]/'image/histogram/rtl/img_hist_ratio_u8.v']
 for t in tests:shutil.copy2(t,regdir/t.name)
 shutil.copy2(sv/'run_histogram_frame_tests.py',regdir/'oracle_source.py')
 results=[]
 with tempfile.TemporaryDirectory(prefix='he_independent_') as tmp:
  profiles=[(0,32,1)]+[(1,b,h) for h in [0,1] for b in [8,12,16,24,32]]
  for adapter,bits,hist in profiles:
   label=f'a{adapter}_w{bits}_h{hist}';folder=Path(tmp)/label;folder.mkdir()
   counts=independent.fixtures(folder,adapter,bits,hist);binary=folder/'sim.vvp'
   execute(['iverilog','-g2012','-s','tb_cip_image_histogram_frame',f'-Ptb_cip_image_histogram_frame.ADAPTER={adapter}',f'-Ptb_cip_image_histogram_frame.DW={bits}',f'-Ptb_cip_image_histogram_frame.HIST={hist}','-o',binary,module,*[regdir/t.name for t in tests]],out,regdir/(label+'_compile.log'))
   result=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],out,regdir/(label+'_simulation.log'),timeout=600)
   if f'HISTOGRAM_FRAME PASS commands={counts["commands"]}' not in result:raise RuntimeError('independent regression failed')
   results.append(dict(adapter=adapter,bits=bits,histogram=hist,**counts))
 (regdir/'summary.json').write_text(json.dumps({'status':'PASS','cases':results},indent=2)+'\n')
 sources=info['sources']
 with tempfile.TemporaryDirectory(prefix='a48_hist_mapping_') as tmp:
  for kind,case in info['verification_cases'].items():
   selected=[out/case['top_source'],*[out/n for n in sources if n!='source/acceptance48_top.v']]
   binary=Path(tmp)/(kind+'.vvp')
   execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*selected,out/case['testbench']],out,out/(kind+'_compile.log'))
   output=execute(['vvp',binary,'+golden='+str(out/case['expected_uart'])],out,out/(kind+'_simulation.log'),timeout=600)
   if 'ACCEPTANCE48 UART GOLDEN PASS' not in output:raise RuntimeError('missing PASS')
 hashes={name:digest(out/name) for name in status['source_sha256'] if name!='case.json'}
 hashes.update({str(p.relative_to(out)).replace('\\','/'):digest(p) for p in regdir.iterdir() if p.suffix in ('.v','.py','.json')});info['source_sha256']=hashes.copy();info['mapping_change']='Capacity-derived COUNT_W=clog2(MAX_WIDTH*MAX_HEIGHT+1); public histogram remains zero-extended32. Single synchronous RAM read/write, unchanged FSM/vectors/UART.'
 info['original_case']=str(old);info['original_build_status_sha256']=digest(old/'build_status.json')
 (out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=digest(out/'case.json')
 (out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n')
 print(json.dumps({'candidate':str(out),'simulation':'PASS','source_sha256':digest(module)}))
if __name__=='__main__':main()

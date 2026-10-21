from pathlib import Path
import argparse,shutil,json,hashlib,tempfile,sys,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
from make_case import execute

def stage(name,version=2):
 base=HERE.parent/'cases'/(name+'_v1');out=HERE/(name+'_v'+str(version))
 if out.exists():raise RuntimeError('must use new case directory')
 out.mkdir()
 for folder in ['source','verification']:shutil.copytree(base/folder,out/folder)
 for file in ['case.json','vectors.json','tang25k.cst','expected_uart.txt']:shutil.copy2(base/file,out/file)
 driver=out/'source/acceptance48_driver.v'
 driver.write_text('// Isolated test harness: synchronous reset requires the continuously running board clock during POR.\n'+driver.read_text().replace('posedge clk or negedge rst_n','posedge clk'))
 if name=='sobel' and version<8:shutil.copy2(HERE/'img_filter_stream_register.v',out/'source/img_filter_stream_register.v')
 if name=='frame_difference' and version>=3:shutil.copy2(HERE/'cip_image_frame_difference.v',out/'source/cip_image_frame_difference.v')
 if name in ['sobel','prewitt','laplacian'] and (version==3 or 6<=version<8 or version>=9):shutil.copy2(HERE/'cip_image_window_filter_frame.v',out/'source/cip_image_window_filter_frame.v')
 if name=='sobel' and 5<=version<8:shutil.copy2(HERE/'img_edge_gradient3x3.v',out/'source/img_edge_gradient3x3.v')
 if name=='sobel' and version==7:shutil.copy2(HERE/'img_window3x3_valid_draft.v',out/'source/img_window3x3_valid_draft.v')
 if version>=5:
  for top in [out/'source/acceptance48_top.v',out/'verification/pixel_fault_top.v']:
   text=top.read_text()
   for rom_name in ['configuration','input_word','expected_word','aux_word','coefficient_word']:
    pattern=r'reg \[([^]]+)\] '+rom_name+r';always @\* begin .*?endcase end'
    def register(match):
     block=match.group(0);bounds=match.group(1)
     return re.sub(r'\b'+rom_name+r'\b',rom_name+'_rom',block)+f'\nreg [{bounds}] {rom_name};always @(posedge clk) {rom_name}<={rom_name}_rom;'
    text,count=re.subn(pattern,register,text,flags=re.S)
    if count!=1:raise RuntimeError('ROM not found '+rom_name)
   top.write_text(text)
 info=json.loads((out/'case.json').read_text())
 with tempfile.TemporaryDirectory(prefix='a48_sync_reset_') as t:
  for kind,cfg in info['verification_cases'].items():
   binary=Path(t)/(kind+'.vvp')
   sources=[out/cfg['top_source']]+[out/x for x in info['sources'][1:]]
   execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*sources,out/cfg['testbench']],out,out/(kind+'_compile.log'))
   text=execute(['vvp',binary,'+golden='+str(out/cfg['expected_uart'])],out,out/(kind+'_simulation.log'))
   if 'ACCEPTANCE48 UART GOLDEN PASS' not in text:raise RuntimeError(kind+' missing verification')
 paths=[out/x for x in info['sources']]+[out/x for x in ['tang25k.cst','vectors.json','expected_uart.txt']]+list((out/'verification').iterdir())
 hashes={str(x.relative_to(out)).replace(chr(92),'/'):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
 info['source_sha256']=hashes;info['simulation']='PASS';info['candidate_note']='Only isolated harness synchronous reset; public DUT unchanged. Board clock must run throughout POR.'
 (out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=hashlib.sha256((out/'case.json').read_bytes()).hexdigest()
 (out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n')
 print(json.dumps({'case':name,'verification':list(info['verification_cases']),'simulation':'PASS'}))
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('name',choices=['window','frame_difference','sobel','prewitt','laplacian']);ap.add_argument('--version',type=int,default=2);args=ap.parse_args();stage(args.name,args.version)

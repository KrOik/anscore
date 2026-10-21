from pathlib import Path
import sys,json,shutil,tempfile,hashlib
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H.parent));sys.path.insert(0,str(H.parent/'window_frame_optimized'));from make_case import execute
from harness_rom_pipeline import register_rom_outputs
base=H.parent/'cases/downsample_v1';out=H/'downsample_v4'
if out.exists():raise RuntimeError('new directory required')
out.mkdir()
for folder in ['source','verification']:shutil.copytree(base/folder,out/folder)
for file in ['case.json','vectors.json','expected_uart.txt','tang25k.cst']:shutil.copy2(base/file,out/file)
for name in ['cip_image_downsample.v','img_geo_area_resample.v','geo_serial_divider.v']:shutil.copy2(H/name,out/'source'/name)
p=out/'source/acceptance48_driver.v';driver=p.read_text().replace('posedge clk or negedge rst_n','posedge clk')
driver=driver.replace('wire bad_response=', '''reg [15:0] ni_previous,no_previous,na_previous,nk_previous;
always @(posedge clk)begin ni_previous<=ni-1'b1;no_previous<=no-1'b1;na_previous<=na-1'b1;nk_previous<=nk-1'b1;end
wire bad_response=''')
for actual,take,target,prev in [('sent','take_s','ni','ni_previous'),('received','take_m','no','no_previous'),('aux_sent','take_a','na','na_previous'),('coeff_sent','take_k','nk','nk_previous')]:
 driver=driver.replace(f'({actual}+{take})!={target}',f'({take}?{actual}!={prev}:{actual}!={target})')
p.write_text(driver)
for p in [out/'source/acceptance48_top.v',out/'verification/pixel_fault_top.v']:p.write_text(register_rom_outputs(p.read_text()))
info=json.loads((out/'case.json').read_text());info['sources'].append('source/geo_serial_divider.v')
with tempfile.TemporaryDirectory(prefix='a48_geo_verify_') as t:
 for kind,cfg in info['verification_cases'].items():
  binary=Path(t)/(kind+'.vvp');sources=[out/cfg['top_source']]+[out/x for x in info['sources'][1:]]
  execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*sources,out/cfg['testbench']],out,out/(kind+'_compile.log'))
  text=execute(['vvp',binary,'+golden='+str(out/cfg['expected_uart'])],out,out/(kind+'_simulation.log'))
  assert 'ACCEPTANCE48 UART GOLDEN PASS' in text
paths=[out/x for x in info['sources']]+[out/x for x in ['tang25k.cst','vectors.json','expected_uart.txt']]+list((out/'verification').iterdir());hashes={str(p.relative_to(out)).replace(chr(92),'/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
info['source_sha256']=hashes;info['simulation']='PASS';info['candidate_note']='Exact shared restoring division, registered area arithmetic, bounded setup; isolated synchronous-reset driver and registered ROM outputs, CE4.'
(out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=hashlib.sha256((out/'case.json').read_bytes()).hexdigest();(out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n');print('downsample_v2 seven UART verification cases PASS')

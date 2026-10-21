from pathlib import Path
import sys,tempfile,json,hashlib,shutil
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(SV))
from tooling import execute
from pointwise_reference import fixtures
out=Path(sys.argv[1]).resolve()
info=json.loads((out/'case.json').read_text())
with tempfile.TemporaryDirectory(prefix='color_pipeline_') as tmp:
 for kind,case in info['verification_cases'].items():
  binary=Path(tmp)/(kind+'.vvp');sources=[out/case['top_source'],*[out/n for n in info['sources'] if n!='source/acceptance48_top.v']]
  execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*sources,out/case['testbench']],out,out/(kind+'_compile.log'))
  text=execute(['vvp',binary,'+golden='+str(out/case['expected_uart'])],out,out/(kind+'_simulation.log'),timeout=600)
  if 'ACCEPTANCE48 UART GOLDEN PASS' not in text:raise RuntimeError('seven-way fail')
 regdir=out/'independent_regression';regdir.mkdir(exist_ok=True)
 original=[SV/'rtl'/f'{name}.v' for name in ['cip_image_pointwise_frame_ctrl','cip_rgb_brightness_contrast','cip_image_invert','cip_image_brightness_contrast','cip_image_color_convert','cip_image_awb']]
 original += [COMMON/'image/geometry/rtl/img_geo_pixel_invert.v',SV/'sim/tb_cip_image_pointwise.v']
 original += [COMMON/'image/isp'/f'{name}.v' for name in ['img_isp_awb_auto','img_isp_awb_stats','img_isp_awb_autogain','img_isp_awb_gain']]
 for p in original:shutil.copy2(p,regdir/p.name)
 shutil.copy2(SV/'pointwise_reference.py',regdir/'pointwise_reference.py')
 sources=[out/'source/img_isp_colorspace.v',*[regdir/p.name for p in original]]
 results=[]
 for kind in [0,1,2,3]:
  for width in [1,8,16,24,32]:
   label=f'kind{kind}_width{width}';folder=Path(tmp)/label;folder.mkdir();counts=fixtures(folder,width,kind);binary=folder/'sim.vvp'
   execute(['iverilog','-g2012','-s','tb_cip_image_pointwise',f'-Ptb_cip_image_pointwise.DW={width}',f'-Ptb_cip_image_pointwise.KIND={kind}','-o',binary,*sources],out,regdir/(label+'_compile.log'))
   text=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]],out,regdir/(label+'_simulation.log'),timeout=600)
   if f'POINTWISE PASS kind={kind} width={width}' not in text:raise RuntimeError('independent failure')
   results.append(counts)
 (regdir/'summary.json').write_text(json.dumps({'status':'PASS','cases':results},indent=2)+'\n')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
hashes={name:digest(out/name) for name in info['source_sha256']}
hashes.update({str(p.relative_to(out)).replace('\\','/'):digest(p) for p in regdir.iterdir() if p.suffix in ('.v','.py','.json')})
info['source_sha256']=hashes.copy();info['mapping_change']='Four-stage synchronous constant-product ROM/pairwise20-bit sums/merge/clip. Enabled latency1->4, II1. Coefficients, rounding, golden and cfg-at-SOF unchanged.'
(out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=digest(out/'case.json')
(out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n')
print(json.dumps({'candidate':str(out),'simulation':'PASS','independent_profiles':len(results),'core_sha256':digest(out/'source/img_isp_colorspace.v')}))

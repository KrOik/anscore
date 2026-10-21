from pathlib import Path
import sys,tempfile,json,hashlib,shutil
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(SV))
from tooling import execute
from image_threshold_reference import fixtures
out=Path(sys.argv[1]).resolve()
info=json.loads((out/'case.json').read_text())
with tempfile.TemporaryDirectory(prefix='color_pipeline_') as tmp:
 for kind,case in info['verification_cases'].items():
  binary=Path(tmp)/(kind+'.vvp');sources=[out/case['top_source'],*[out/n for n in info['sources'] if n!='source/acceptance48_top.v']]
  execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*sources,out/case['testbench']],out,out/(kind+'_compile.log'))
  text=execute(['vvp',binary,'+golden='+str(out/case['expected_uart'])],out,out/(kind+'_simulation.log'),timeout=600)
  if 'ACCEPTANCE48 UART GOLDEN PASS' not in text:raise RuntimeError('seven-way fail')
 regdir=out/'independent_regression';regdir.mkdir(exist_ok=True)
 root=COMMON.parents[1]
 original=[SV/'rtl/cip_image_threshold.v',SV/'rtl/cip_image_threshold_fixed.v',SV/'sim/tb_cip_image_threshold.v',SV/'sim/tb_cip_image_threshold_modes.v']
 original += [root/line.strip() for line in (COMMON/'image/rtl_sources.f').read_text().splitlines() if line.strip() and not line.startswith('#')]
 sources=[]
 for p in original:
  if p.name in ('img_hist_serial_multiply.v','img_hist_otsu_threshold.v','img_hist_otsu_frame.v','img_filter_adaptive_mean3x3.v','img_filter_adaptive_gaussian3x3.v','img_adaptive_threshold_frame.v'):sources.append(out/'source'/p.name);continue
  target=regdir/p.name
  # Keep the previously staged immutable dependency snapshot on verification retries.
  if not target.exists():shutil.copy2(p,target)
  sources.append(target)
 shutil.copy2(SV/'image_threshold_reference.py',regdir/'image_threshold_reference.py')
 results=[]
 for width in [1,8,16,24,32]:
  folder=Path(tmp)/f'w{width}';folder.mkdir();binary=folder/'sim.vvp'
  for modes in [False,True]:
   top='tb_cip_image_threshold_modes' if modes else 'tb_cip_image_threshold';label=f'w{width}_modes{int(modes)}'
   execute(['iverilog','-g2012','-s',top,f'-P{top}.DW={width}','-o',binary,*sources],out,regdir/(label+'_compile.log'))
   argv=['vvp',binary]
   counts={}
   if modes:
    counts=fixtures(folder,width)
    argv += [f'+folder={folder}',*[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]]
   text=execute(argv,out,regdir/(label+'_simulation.log'),timeout=600)
   marker=f'THRESHOLD_MODES PASS width={width}' if modes else f'THRESHOLD_ADAPTER PASS width={width}'
   if marker not in text:raise RuntimeError('independent failure')
   results.append(dict(counts,width=width,modes=modes))
 (regdir/'summary.json').write_text(json.dumps({'status':'PASS','cases':results},indent=2)+'\n')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
hashes={name:digest(out/name) for name in info['source_sha256']}
hashes.update({str(p.relative_to(out)).replace('\\','/'):digest(p) for p in regdir.iterdir() if p.suffix in ('.v','.py','.json')})
info['source_sha256']=hashes.copy();info['mapping_change']='Exact carry-save serial multiply with byte final carry fold; optional candidate registered load/scan weights and byte-serial delta subtract. Arithmetic, ready/valid, original vectors and lowest-threshold tie-break unchanged; latency increases are covered by original independent tests.'
(out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=digest(out/'case.json')
(out/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n')
print(json.dumps({'candidate':str(out),'simulation':'PASS','independent_profiles':len(results),'core_sha256':digest(out/'source/img_hist_serial_multiply.v')}))


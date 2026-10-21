from pathlib import Path
import sys,json,hashlib,shutil,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[2]/'integration'));from tooling import execute
sys.path.insert(0,str(HERE/'window_frame_optimized'));from harness_rom_pipeline import register_rom_outputs
old=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve();runner=sys.argv[3]
assert not out.exists()
status=json.loads((old/'build_status.json').read_text())
for name,expected in status['source_sha256'].items():
 source=old/name
 assert hashlib.sha256(source.read_bytes()).hexdigest()==expected,name
 target=out/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
shutil.copy2(Path(sys.argv[4]) if len(sys.argv)>4 else HERE/'cases/upsample_harness_v5/source/img_geo_inverse_map.v',out/'source/img_geo_inverse_map.v')
if len(sys.argv)>5:shutil.copy2(Path(sys.argv[5]),out/'source/cip_image_rotate_angle_frame.v')
shutil.copy2(HERE/'geo_optimized/downsample_v4/source/acceptance48_driver.v',out/'source/acceptance48_driver.v')
for p in [out/'source/acceptance48_top.v',*(out/'verification').glob('*_top.v')]:
 text=p.read_text()
 if 'configuration_rom' not in text:p.write_text(register_rom_outputs(text))
info=json.loads((out/'case.json').read_text())
with tempfile.TemporaryDirectory(prefix='a48_geo_mapper_') as tmp:
 for kind,case in info['verification_cases'].items():
  binary=Path(tmp)/(kind+'.vvp');sources=[out/case['top_source'],*[out/n for n in info['sources'] if n!='source/acceptance48_top.v']]
  execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*sources,out/case['testbench']],out,out/(kind+'_compile.log'))
  text=execute(['vvp',binary,'+golden='+str(out/case['expected_uart'])],out,out/(kind+'_simulation.log'),timeout=600)
  assert 'ACCEPTANCE48 UART GOLDEN PASS' in text
sys.path.insert(0,str(HERE.parents[2]/'signal_video'));tests=__import__(runner)
original=tests.execute;regdir=out/'independent_regression';regdir.mkdir(exist_ok=True)
def candidate_execute(command,cwd,log,**kwargs):
 command=[out/'source'/Path(str(p)).name if (out/'source'/Path(str(p)).name).is_file() else p for p in command]
 return original(command,cwd,regdir/Path(log).name,**kwargs)
tests.execute=candidate_execute;tests.evidence_dir=lambda label:regdir;tests.main()
info['mapping_change']='Registered byte-borrow divider preserves2cycles/bit. Matrix CSA plus registeredbyte sum/carry stage adds1enabledcycle to affine/perspective (affine3,perspective242), scale240unchanged. Qualified synchronous driver and5registeredROM outputs, CE_DIV4; original goldens unchanged.' if len(sys.argv)>4 else 'Exact board-proven registered byte-borrow divider; unchanged2cycles/bit and arithmetic. Qualified synchronous driver and5registeredROM outputs, CE_DIV4; original goldens unchanged.'
if 'ST_MATRIX_MUL' in (out/'source/img_geo_inverse_map.v').read_text():info['mapping_change']='Exact signed32xunsigned16 CSA shiftadd16cycles+6bytefold; matrixCSA registeredsum; affine25,perspective264,scale240enabledcycles. Original goldens unchanged; CE_DIV4 qualified isolated harness.'
hashes={n:hashlib.sha256((out/n).read_bytes()).hexdigest() for n in info['source_sha256'] if n!='case.json'}
info['source_sha256']=hashes.copy();(out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=hashlib.sha256((out/'case.json').read_bytes()).hexdigest()
(out/'build_status.json').write_text(json.dumps(dict(status='SIMULATION_PASS',simulation='PASS',source_sha256=hashes),indent=2)+'\n');print('GEO MAPPER ALL PASS '+str(out))

"""Original unchanged SR public regression or seven UART acceptance cases."""
from pathlib import Path
import sys,json,shutil,tempfile,importlib.util,hashlib,datetime
C=Path(__file__).resolve().parent
SV=C.parents[4]/'signal_video'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
if '--uart' in sys.argv:
 sys.path.insert(0,str(C.parents[1]));from make_case import execute
 info=json.loads((C/'case.json').read_text())
 with tempfile.TemporaryDirectory(prefix='a48_sr4_uart_') as tmp:
  for kind,cfg in info['verification_cases'].items():
   binary=Path(tmp)/(kind+'.vvp')
   sources=[C/cfg['top_source']]+[C/n for n in info['sources'][1:]]
   execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*sources,C/cfg['testbench']],C,C/(kind+'_compile.log'))
   result=execute(['vvp',binary,'+golden='+str(C/cfg['expected_uart'])],C,C/(kind+'_simulation.log'))
   assert 'ACCEPTANCE48 UART GOLDEN PASS' in result
 paths=[C/n for n in info['sources']]+[C/n for n in ['tang25k.cst','vectors.json','expected_uart.txt']]+list((C/'verification').iterdir())
 hashes={str(p.relative_to(C)).replace(chr(92),'/'):sha(p) for p in paths}
 info['source_sha256']=hashes;info['simulation']='PASS'
 info['candidate_note']='SR narrow bounded counters/addresses; tap_x/y remove dynamic3/5 division/modulo; single synchronous coefficient read port/blockRAM across atomic model banks; same arithmetic/cadence. Inherited v3 registered harness,CE4.'
 (C/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=sha(C/'case.json')
 (C/'build_status.json').write_text(json.dumps({'status':'SIMULATION_PASS','simulation':'PASS','source_sha256':hashes},indent=2)+'\n')
 print('SR_V5 seven UART PASS; original goldens/watchdogs retained')
else:
 log=C/('original_public_regression_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'));log.mkdir(exist_ok=False)
 with tempfile.TemporaryDirectory(prefix='a48_sr4_freeze_') as tmp:
  snap=Path(tmp)/'signal_video';(snap/'rtl').mkdir(parents=True);(snap/'sim').mkdir()
  shutil.copy2(C/'source/cip_image_super_resolution.v',snap/'rtl/cip_image_super_resolution.v')
  shutil.copy2(SV/'sim/tb_cip_image_super_resolution.v',snap/'sim/tb_cip_image_super_resolution.v')
  shutil.copy2(SV/'run_super_resolution_tests.py',snap/'run_super_resolution_tests.py')
  sys.path.insert(0,str(SV.parent/'integration'))
  spec=importlib.util.spec_from_file_location('original_sr',SV/'run_super_resolution_tests.py')
  module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  module.HERE=snap;module.__file__=str(snap/'run_super_resolution_tests.py');module.evidence_dir=lambda tag:log
  module.main()

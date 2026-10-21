from pathlib import Path
import sys,json,tempfile,hashlib,shutil
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2]
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(COMMON/'signal_video'))
from tooling import execute
out=Path(sys.argv[1]).resolve();info=json.loads((out/'case.json').read_text())
with tempfile.TemporaryDirectory(prefix='a48_upsample_') as tmp:
 for kind,case in info['verification_cases'].items():
  binary=Path(tmp)/(kind+'.vvp');sources=[out/case['top_source'],*[out/n for n in info['sources'] if n!='source/acceptance48_top.v']]
  execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*sources,out/case['testbench']],out,out/(kind+'_compile.log'))
  text=execute(['vvp',binary,'+golden='+str(out/case['expected_uart'])],out,out/(kind+'_simulation.log'),timeout=600)
  if 'ACCEPTANCE48 UART GOLDEN PASS' not in text:raise RuntimeError('UART failure')
import run_upsample_tests as tests
original=tests.execute
regdir=out/'independent_regression';regdir.mkdir(exist_ok=True)
def candidate_execute(command,cwd,log,**kwargs):
 command=[out/'source'/Path(str(p)).name if (out/'source'/Path(str(p)).name).is_file() else p for p in command]
 return original(command,cwd,regdir/Path(log).name,**kwargs)
tests.execute=candidate_execute
tests.evidence_dir=lambda label:regdir
tests.main()
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
hashes={n:digest(out/n) for n in info['source_sha256'] if n!='case.json'}
info['source_sha256']=hashes.copy();info['mapping_change']='Byte-parallel exact29-bit divider subtract with explicit borrow prefix; no state/latency/golden changes.'
(out/'case.json').write_text(json.dumps(info,indent=2)+'\n');hashes['case.json']=digest(out/'case.json')
(out/'build_status.json').write_text(json.dumps(dict(status='SIMULATION_PASS',simulation='PASS',source_sha256=hashes),indent=2)+'\n')
print(json.dumps(dict(candidate=str(out),status='PASS',reference_profiles=6)))

from pathlib import Path
import sys,tempfile,json,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
results=[]
for capacity,frac in ((32,8),(64,16)):
 with tempfile.TemporaryDirectory(prefix='affine_synth_') as td:
  txt=execute(['yosys','-p',f'read_verilog -sv {(HERE/"affine_ransac.sv").as_posix()}; chparam -set CAPACITY {capacity} -set FRAC {frac} affine_ransac; synth_gowin -top affine_ransac -noalu -nodsp; stat'],td,HERE/f'synthesis_c{capacity}_q{frac}.log',timeout=300)
  assert 'Found and reported 0 problems.' in txt
  last=txt.rsplit('=== affine_ransac ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
  results.append({'result':'PASS','config':f'CAPACITY{capacity} FRAC{frac}','flow':'synth_gowin -noalu -nodsp','cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n');print(results)

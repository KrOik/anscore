from pathlib import Path
import sys,tempfile,json,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
results=[]
for bits,win in ((8,3),(12,5)):
 with tempfile.TemporaryDirectory(prefix='lk_synth_') as td:
  txt=execute(['yosys','-p',f'read_verilog -sv {(HERE/"dense_lucas_kanade.sv").as_posix()}; chparam -set BITS {bits} -set WINDOW {win} dense_lucas_kanade; synth_gowin -top dense_lucas_kanade -noalu -nodsp; stat'],td,HERE/f'synthesis_b{bits}_w{win}.log',timeout=300)
  assert 'Found and reported 0 problems.' in txt
  last=txt.rsplit('=== dense_lucas_kanade ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
  results.append({'result':'PASS','config':f'16x16 BITS{bits} WINDOW{win} FRAC8 OUT_BITS24','flow':'synth_gowin -noalu -nodsp','cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n');print(results)

from pathlib import Path
import sys,tempfile,re,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
results=[]
for length in (128,256):
 with tempfile.TemporaryDirectory(prefix='brief_synth_') as td:
  text=execute(['yosys','-p',f'read_verilog -sv {(HERE/"brief_descriptor.sv").as_posix()}; chparam -set DESC_BITS {length} brief_descriptor; synth_gowin -top brief_descriptor -noalu -nodsp; stat'],td,HERE/f'synthesis_{length}.log',timeout=300)
  last=text.rsplit('=== brief_descriptor ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
  results.append({'result':'PASS','config':f'16x16 BITS8 DESC_BITS{length} RADIUS3','flow':'synth_gowin -noalu -nodsp','cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n')

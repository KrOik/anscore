from pathlib import Path
import sys,tempfile,re,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
results=[]
for length in (128,256):
 with tempfile.TemporaryDirectory(prefix='descriptor_match_synth_') as td:
  output=execute(['yosys','-p',f'read_verilog -sv {(HERE/"descriptor_match.sv").as_posix()}; chparam -set DESC_BITS {length} descriptor_match; synth_gowin -top descriptor_match -noalu -nodsp; check; stat'],td,HERE/f'synthesis_{length}.log',timeout=300)
  final=output.rsplit('=== descriptor_match ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',final,re.M)}
  results.append({'status':'PASS','descriptor_bits':length,'capacity':16,'cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n');print(results)

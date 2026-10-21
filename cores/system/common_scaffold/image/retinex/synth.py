from pathlib import Path
import sys,tempfile,re,json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute,ROOT
results=[]
for bits in (8,12):
 with tempfile.TemporaryDirectory(prefix='retinex_synth_') as td:
  out=execute(['yosys','-p',f'read_verilog -sv {(HERE/"retinex_ssr.sv").as_posix()}; chparam -set WIDTH 9 -set HEIGHT 7 -set BITS {bits} retinex_ssr; synth_gowin -top retinex_ssr -noalu -nodsp; check; stat'],ROOT,HERE/f'synthesis_{bits}.log',timeout=300)
  final=out.rsplit('=== retinex_ssr ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',final,re.M)}
  results.append({'status':'PASS','configuration':f'9x7 B{bits}','cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n');print(results)

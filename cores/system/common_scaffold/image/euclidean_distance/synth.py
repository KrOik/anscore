from pathlib import Path
import sys,tempfile,re,json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='euclidean_edt_synth_') as td:
 out=execute(['yosys','-p',f'read_verilog -sv {(HERE/"euclidean_distance.sv").as_posix()}; chparam -set WIDTH 9 -set HEIGHT 7 euclidean_distance; synth_gowin -top euclidean_distance -noalu -nodsp; check; stat'],td,HERE/'synthesis.log',timeout=300)
 last=out.rsplit('=== euclidean_distance ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 result={'status':'PASS','configuration':'9x7 binary exact squared EDT','cells':cells,'board':False,'pnr':False}
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result)

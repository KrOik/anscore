from pathlib import Path
import sys,tempfile,re,json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='motion_comp_synth_') as td:
 output=execute(['yosys','-p',f'read_verilog -sv {(HERE/"motion_compensation.sv").as_posix()}; chparam -set WIDTH 9 -set HEIGHT 7 -set BITS 8 -set BLOCK_W 4 -set BLOCK_H 3 motion_compensation; synth_gowin -top motion_compensation -noalu -nodsp; check; stat'],td,HERE/'synthesis.log',timeout=300)
 final=output.rsplit('=== motion_compensation ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',final,re.M)}
 result={'status':'PASS','configuration':'9x7 B8 blocks4x3','cells':cells,'board':False,'pnr':False}
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result)

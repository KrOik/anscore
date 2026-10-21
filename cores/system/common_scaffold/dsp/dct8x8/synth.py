from pathlib import Path
import sys,tempfile,json,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='dct8x8_synth_') as td:
 text=execute(['yosys','-p',f'read_verilog -sv {(HERE/"dct8x8_serial.sv").as_posix()}; synth_gowin -top dct8x8_serial -noalu -nodsp; stat'],td,HERE/'synthesis.log',timeout=300)
 last=text.rsplit('=== dct8x8_serial ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 (HERE/'synthesis.json').write_text(json.dumps({'status':'PASS','config':'BITS16','flow':'synth_gowin -noalu -nodsp','cells':cells,'board':False,'pnr':False},indent=2)+'\n')

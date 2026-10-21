from pathlib import Path
import sys,tempfile,re,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='quant_synth_') as td:
 text=execute(['yosys','-p',f'read_verilog -sv {(HERE/"jpeg_quant_zigzag.sv").as_posix()}; synth_gowin -top jpeg_quant_zigzag -noalu -nodsp; stat'],td,HERE/'synthesis.log',timeout=300)
 last=text.rsplit('=== jpeg_quant_zigzag ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 (HERE/'synthesis.json').write_text(json.dumps({'result':'PASS','flow':'synth_gowin -noalu -nodsp','config':'BITS16','cells':cells,'board':False,'pnr':False},indent=2)+'\n')

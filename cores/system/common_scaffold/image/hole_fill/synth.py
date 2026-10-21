from pathlib import Path
import sys,tempfile,re,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
results=[]
for conn in (0,1):
 with tempfile.TemporaryDirectory(prefix='hole_synth_') as td:
  text=execute(['yosys','-p',f'read_verilog -sv {(HERE/"binary_hole_fill.sv").as_posix()}; chparam -set CONNECT8 {conn} binary_hole_fill; synth_gowin -top binary_hole_fill -noalu -nodsp; stat'],td,HERE/f'synthesis_c{conn}.log',timeout=300)
  last=text.rsplit('=== binary_hole_fill ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
  results.append({'result':'PASS','config':f'16x16 CONNECT8{conn}','flow':'synth_gowin -noalu -nodsp','cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n')

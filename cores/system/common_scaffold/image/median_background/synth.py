from pathlib import Path
import sys,tempfile,re,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
results=[]
for window in (3,5):
 with tempfile.TemporaryDirectory(prefix='median_bg_synth_') as td:
  text=execute(['yosys','-p',f'read_verilog -sv {(HERE/"temporal_median_background.sv").as_posix()}; chparam -set WINDOW {window} temporal_median_background; synth_gowin -top temporal_median_background -noalu -nodsp; stat'],td,HERE/f'synthesis_w{window}.log',timeout=300)
  last=text.rsplit('=== temporal_median_background ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
  results.append({'result':'PASS','config':f'WIDTH8 HEIGHT6 BITS8 WINDOW{window}','flow':'synth_gowin -noalu -nodsp','cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n')

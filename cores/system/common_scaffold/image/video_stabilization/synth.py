from pathlib import Path
import sys,tempfile,json,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='stabilization_synth_') as td:
 txt=execute(['yosys','-p',f'read_verilog -sv {(HERE/"affine_video_stabilizer.sv").as_posix()}; synth_gowin -top affine_video_stabilizer -noalu -nodsp; stat'],td,HERE/'synthesis.log',timeout=300)
 assert 'Found and reported 0 problems.' in txt
 last=txt.rsplit('=== affine_video_stabilizer ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 result={'result':'PASS','flow':'synth_gowin -noalu -nodsp','cells':cells,'board':False,'pnr':False}
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result)

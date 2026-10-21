from pathlib import Path
import sys,hashlib
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
here=Path(__file__).resolve().parent;source=here/'img_fast9_frame.sv'
folder=evidence_dir('fast9_synth')
cmd=f'read_verilog -sv {source.as_posix()}; synth_gowin -top img_fast9_frame -noalu -nodsp; check -assert; stat'
output=execute(['yosys','-p',cmd],ROOT,folder/'synthesis.log',timeout=180)
write_json(folder/'result.json',{'status':'PASS','rtl_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'board_tested':False})
print(output[output.rfind('=== img_fast9_frame ==='):]);print(folder)

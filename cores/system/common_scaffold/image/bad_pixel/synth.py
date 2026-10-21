from pathlib import Path
import sys,hashlib
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
here=Path(__file__).resolve().parent;source=here/'raw_bad_pixel_frame.sv'
folder=evidence_dir('bad_pixel_synth')
cmd=f'read_verilog -sv {source.as_posix()}; synth_gowin -top raw_bad_pixel_frame -noalu -nodsp; check -assert; stat'
output=execute(['yosys','-p',cmd],ROOT,folder/'synthesis.log',timeout=180)
write_json(folder/'result.json',{'status':'PASS','rtl_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'board_tested':False})
print(output[output.rfind('=== raw_bad_pixel_frame ==='):]);print(folder)

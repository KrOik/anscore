from pathlib import Path
import sys,hashlib
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
here=Path(__file__).resolve().parent
source=here/'jpeg_entropy_bitpacker.sv'
folder=evidence_dir('jpeg_bitstream_synth')
command=f'read_verilog -sv {source.as_posix()}; synth_gowin -top jpeg_entropy_bitpacker -noalu -nodsp; check -assert; stat'
output=execute(['yosys','-p',command],ROOT,folder/'synthesis.log')
write_json(folder/'result.json',{'status':'PASS','rtl_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'board_tested':False})
print(output[output.rfind('=== jpeg_entropy_bitpacker ==='):]);print(folder)

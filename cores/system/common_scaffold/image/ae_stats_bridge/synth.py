from pathlib import Path
import hashlib
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
here=Path(__file__).resolve().parent
source=here/'ispstats_ae_bridge.sv'
folder=evidence_dir('stats_ae_bridge_synth')
command=f'read_verilog -sv {source.as_posix()}; synth_gowin -top ispstats_ae_bridge -noalu -nodsp; check -assert; stat'
output=execute(['yosys','-p',command],ROOT,folder/'synthesis.log')
write_json(folder/'result.json',{'status':'PASS','rtl_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
                              'scope':'isolated default parameters; no P&R or board test'})
print(output[output.rfind('=== ispstats_ae_bridge ==='):])
print(folder)

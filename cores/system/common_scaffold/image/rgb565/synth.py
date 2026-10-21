from pathlib import Path
import sys,hashlib,re
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
here=Path(__file__).resolve().parent
folder=evidence_dir('rgb565_synth')
profiles=[]
for pack,rounding in ((0,0),(1,0),(1,1)):
    cmd=f'read_verilog -sv {(here/"rgb565_stream.sv").as_posix()}; chparam -set PACK {pack} -set ROUND_NEAREST {rounding} rgb565_stream; synth_gowin -top rgb565_stream -noalu -nodsp; check -assert; stat'
    output=execute(['yosys','-p',cmd],ROOT,folder/f'p{pack}_r{rounding}.log')
    stats=output[output.rfind('=== rgb565_stream ==='):]
    cells={kind:int(n) for n,kind in re.findall(r'^\s+(\d+)\s+([A-Z][A-Z0-9_]*)\s*$',stats,re.M)}
    profiles.append({'pack':pack,'round_nearest':rounding,'cells':cells,'status':'PASS'})
write_json(folder/'results.json',{'profiles':profiles,'rtl_sha256':hashlib.sha256((here/'rgb565_stream.sv').read_bytes()).hexdigest(),'board_tested':False})
print(profiles);print(folder)

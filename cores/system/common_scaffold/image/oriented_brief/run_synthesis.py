from pathlib import Path
import sys,tempfile,re,json
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute,ROOT
with tempfile.TemporaryDirectory(prefix='oriented_brief_synth_') as td:
 text=execute(['yosys','-p',f'read_verilog -sv {(H/"oriented_brief_frame.sv").as_posix()}; synth_gowin -top oriented_brief_frame -noalu -nodsp; stat'],ROOT,H/'synthesis.log',timeout=300)
 last=text.rsplit('=== oriented_brief_frame ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))
 dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','ALU54','DSP')))
 result={'result':'PASS' if lut<=15000 and dsp<=4 else 'FAIL','config':'40x40 BITS8 RADIUS15 16bins 256bits','cells':cells,'lut_class':lut,'dsp':dsp,'board':False,'pnr':False}
 (H/'synthesis_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));assert result['result']=='PASS'

from pathlib import Path
import sys,tempfile,re,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
rows=[]
for width,height in ((16,12),(24,16)):
 text=execute(['yosys','-Q','-p',f'read_verilog -sv {(H/"defect_map.sv").as_posix()}; chparam -set WIDTH {width} -set HEIGHT {height} defect_map; synth_gowin -top defect_map -noalu -nodsp; check -assert; stat'],ROOT,H/f'synthesis_{width}x{height}.log',timeout=300)
 last=text.rsplit('=== defect_map ===',1)[1];cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','DSP','ALU54')))
 bram=sum(v for k,v in cells.items() if k in ('SP','DP','DPB','SDP','SDPB','SPX9','DPX9B','SDPX9B'))
 row={'result':'PASS' if lut<=15000 and dsp<=4 and bram>=3 else 'FAIL','width':width,'height':height,'bits':12,'cells':cells,'lut_class_including_lutram':lut,'dsp':dsp,'block_primitives':bram};rows.append(row);print(json.dumps(row),flush=True);assert row['result']=='PASS'
(H/'synthesis_evidence.json').write_text(json.dumps({'result':'PASS','cases':rows,'rtl_sha256':hashlib.sha256((H/'defect_map.sv').read_bytes()).hexdigest(),'board':False,'pnr':False},indent=2)+'\n')

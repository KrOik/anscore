from pathlib import Path
import sys,tempfile,re,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
rows=[]
for index in (4,6):
 with tempfile.TemporaryDirectory(prefix='raw_gamma_synth_') as td:
  text=execute(['yosys','-Q','-p',f'read_verilog -sv {(H/"raw_gamma.sv").as_posix()}; chparam -set INDEX_BITS {index} raw_gamma; synth_gowin -top raw_gamma -noalu -nodsp; check -assert; stat'],ROOT,H/f'synthesis_i{index}.log',timeout=300)
  last=text.rsplit('=== raw_gamma ===',1)[1];cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','DSP','ALU54')))
  bram=sum(v for k,v in cells.items() if k in ('SP','DP','DPB','SDP','SDPB','SPX9','DPX9B','SDPX9B'))
  row={'result':'PASS' if lut<=15000 and dsp<=4 and bram>0 else 'FAIL','input_bits':12,'output_bits':12,'nodes':(1<<index)+1,'cells':cells,'lut_class_including_lutram':lut,'dsp':dsp,'block_primitives':bram};rows.append(row);print(json.dumps(row),flush=True);assert row['result']=='PASS'
(H/'synthesis_evidence.json').write_text(json.dumps({'result':'PASS','cases':rows,'rtl_sha256':hashlib.sha256((H/'raw_gamma.sv').read_bytes()).hexdigest(),'board':False,'pnr':False},indent=2)+'\n')

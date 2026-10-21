from pathlib import Path
import sys,tempfile,re,json,hashlib,argparse
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
args=argparse.ArgumentParser();args.add_argument('--radius15',action='store_true');args=args.parse_args()
tag='_r15' if args.radius15 else ''
params='chparam -set WIDTH 71 -set HEIGHT 69 -set BITS 10 -set LEVELS 2 -set RADIUS 15 multiscale_features_frame;' if args.radius15 else ''
with tempfile.TemporaryDirectory(prefix='multiscale_features_synth_') as td:
 text=execute(['yosys','-p',f'read_verilog -sv {(H/"multiscale_features_frame.sv").as_posix()}; {params} synth_gowin -top multiscale_features_frame -noalu -nodsp; check -assert; stat'],ROOT,H/f'synthesis{tag}.log',timeout=600)
 last=text.rsplit('=== multiscale_features_frame ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
 dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','DSP','ALU54')))
 bram9=sum(v*2 for k,v in cells.items() if k in ('SP','DP','SDP','DPB','SDPB','DPX9B','SDPX9B','SPX9'))
 result={'result':'PASS' if lut<=15000 and dsp<=4 and bram9<=46 else 'FAIL','config':'71x69 BITS10 LEVELS2 RADIUS15' if args.radius15 else '65x65 BITS8 LEVELS3 RADIUS3','cells':cells,'lut_class_including_lutram':lut,'dsp':dsp,'conservative_bram9_units':bram9,'device_bram9_limit':46,'board':False,'pnr':False,'rtl_sha256':hashlib.sha256((H/'multiscale_features_frame.sv').read_bytes()).hexdigest()}
 (H/f'synthesis{tag}_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));assert result['result']=='PASS'

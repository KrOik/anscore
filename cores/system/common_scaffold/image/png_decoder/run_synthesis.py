from pathlib import Path
import sys,re,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
rows=[]
for profile,mw,mh,mc in [('default',16,12,4096),('max_memory',256,256,8192)]:
 text=execute(['yosys','-Q','-p',f'read_verilog -sv {(H/"png_decoder.sv").as_posix()}; chparam -set MAX_WIDTH {mw} -set MAX_HEIGHT {mh} -set MAX_COMPRESSED_BYTES {mc} png_decoder; synth_gowin -top png_decoder -noalu -nodsp; check -assert; stat'],ROOT,H/f'synthesis_{profile}.log',timeout=600)
 last=text.rsplit('=== png_decoder ===',1)[1];cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','DSP','ALU54')))
 ram9=sum(v*2 for k,v in cells.items() if k in ('SP','DP','DPB','SDP','SDPB','SPX9','DPX9B','SDPX9B'))
 row={'profile':profile,'max_width':mw,'max_height':mh,'max_compressed_bytes':mc,'result':'PASS' if lut<=15000 and dsp<=4 and 29<=ram9<=46 else 'FAIL','cells':cells,'lut_class_including_lutram':lut,'dsp':dsp,'conservative_bram9_units':ram9};rows.append(row);print(json.dumps(row),flush=True);assert row['result']=='PASS'
(H/'synthesis_evidence.json').write_text(json.dumps({'result':'PASS','cases':rows,'rtl_sha256':hashlib.sha256((H/'png_decoder.sv').read_bytes()).hexdigest(),'board':False,'pnr':False},indent=2)+'\n')

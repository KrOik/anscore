from pathlib import Path
import sys,tempfile,re,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
rows=[]
for d,bits,frac in ((16,16,4),(32,24,8)):
 with tempfile.TemporaryDirectory(prefix='subpixel_synth_') as td:
  tag=f'd{d}_b{bits}_q{frac}'
  text=execute(['yosys','-Q','-p',f'read_verilog -sv {(H/"stereo_subpixel.sv").as_posix()}; chparam -set DISPARITIES {d} -set COST_BITS {bits} -set FRAC_BITS {frac} stereo_subpixel; synth_gowin -top stereo_subpixel -noalu -nodsp; check -assert; stat'],ROOT,H/f'{tag}_synthesis.log',timeout=300)
  last=text.rsplit('=== stereo_subpixel ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
  dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','DSP','ALU54')))
  row={'result':'PASS' if lut<=15000 and dsp<=4 else 'FAIL','disparities':d,'cost_bits':bits,'frac_bits':frac,'cells':cells,'lut_class_including_lutram':lut,'dsp':dsp};rows.append(row);print(json.dumps(row),flush=True);assert row['result']=='PASS'
(H/'synthesis_evidence.json').write_text(json.dumps({'result':'PASS','cases':rows,'rtl_sha256':hashlib.sha256((H/'stereo_subpixel.sv').read_bytes()).hexdigest(),'board':False,'pnr':False},indent=2)+'\n')

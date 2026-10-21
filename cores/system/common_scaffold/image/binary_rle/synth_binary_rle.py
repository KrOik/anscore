"""Isolated encoder/decoder mapping; retain compact statistics only."""
import tempfile,subprocess,json
from test_binary_rle import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='binary_rle_synth_') as temporary:
 for module in ('binary_rle_encoder','binary_rle_decoder'):
  for w,h in ((32,32),(65535,65535)):
   script=f'read_verilog {(ROOT/(module+".v")).as_posix()}; chparam -set WIDTH {w} -set HEIGHT {h} {module}; synth_gowin -top {module}; check -assert; stat'
   p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=180)
   if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
   stat=p.stdout[p.stdout.rfind(f'=== {module} ==='):].strip()
   if any(cell in stat for cell in ('MULT9X9','MULT18X18','MULT36X36','DPB','DPX9B','SDPX9B')):raise AssertionError('unexpected DSP/RAM use')
   results.append({'top':module,'width':w,'height':h,'check':'PASS','stat':stat})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS encoder and decoder isolated synthesis/CHECK, zero DSP/RAM')

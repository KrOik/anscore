"""Isolated mapping and CHECK; generated netlists remain temporary."""
import tempfile,subprocess,json
from test_morph_reconstruct import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='morphrec_synth_') as temporary:
 for bits,w,h in ((8,32,32),(12,64,48)):
  script=f'read_verilog {(ROOT/"morph_reconstruct_frame.v").as_posix()}; chparam -set BITS {bits} -set WIDTH {w} -set HEIGHT {h} morph_reconstruct_frame; synth_gowin -top morph_reconstruct_frame; check -assert; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  stat=p.stdout[p.stdout.rfind('=== morph_reconstruct_frame ==='):].strip()
  if any(cell in stat for cell in ('MULT9X9','MULT18X18','MULT36X36')):raise AssertionError('unexpected DSP use')
  results.append({'bits':bits,'width':w,'height':h,'check':'PASS','stat':stat})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis and CHECK')

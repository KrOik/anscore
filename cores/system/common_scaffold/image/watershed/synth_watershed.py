"""Isolated mapping and CHECK; generated netlists remain temporary."""
import tempfile,subprocess,json
from test_watershed import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='watershed_synth_') as temporary:
 for bits,w,h in ((8,32,32),(12,64,64)):
  script=f'read_verilog {(ROOT/"watershed_priority_frame.v").as_posix()}; chparam -set BITS {bits} -set WIDTH {w} -set HEIGHT {h} watershed_priority_frame; synth_gowin -top watershed_priority_frame; check -assert; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  stat=p.stdout[p.stdout.rfind('=== watershed_priority_frame ==='):].strip()
  if any(cell in stat for cell in ('MULT9X9','MULT18X18','MULT36X36')):raise AssertionError('unexpected DSP use')
  results.append({'bits':bits,'width':w,'height':h,'check':'PASS','stat':stat})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis and CHECK')


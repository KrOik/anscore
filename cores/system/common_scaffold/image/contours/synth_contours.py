"""Isolated mapping and CHECK; generated netlists remain temporary."""
import tempfile,subprocess,json
from test_contours import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='contours_synth_') as temporary:
 for w,h in ((32,32),(64,64)):
  script=f'read_verilog {(ROOT/"contours_cell_edges.v").as_posix()}; chparam -set WIDTH {w} -set HEIGHT {h} contours_cell_edges; synth_gowin -top contours_cell_edges; check -assert; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  stat=p.stdout[p.stdout.rfind('=== contours_cell_edges ==='):].strip()
  if any(cell in stat for cell in ('MULT9X9','MULT18X18','MULT36X36')):raise AssertionError('unexpected DSP use')
  results.append({'width':w,'height':h,'check':'PASS','stat':stat})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis and CHECK')


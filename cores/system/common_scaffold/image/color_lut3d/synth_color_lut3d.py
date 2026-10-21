"""Isolated resource mapping; no timing or board claims."""
import tempfile,subprocess,json
from test_color_lut3d import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='color_lut3d_synth_'):
 for bits,gl in ((8,1),(10,2),(12,4)):
  script=f'read_verilog {(ROOT/"color_lut3d.v").as_posix()}; chparam -set BITS {bits} -set GRID_LOG2 {gl} color_lut3d; synth_gowin -top color_lut3d; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
  results.append({'bits':bits,'grid_log2':gl,'stat':p.stdout[p.stdout.rfind('=== color_lut3d ==='):].strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis')

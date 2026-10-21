"""Isolated resource mapping; temporary compile products are not retained."""
import tempfile,subprocess,json
from test_hough_lines import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='hough_synth_'):
 for w,h,cw in ((64,48,16),(640,480,16)):
  script=f'read_verilog {(ROOT/"hough_lines4.v").as_posix()}; chparam -set WIDTH {w} -set HEIGHT {h} -set COUNT_W {cw} hough_lines4; synth_gowin -top hough_lines4; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
  results.append({'width':w,'height':h,'count_bits':cw,'stat':p.stdout[p.stdout.rfind('=== hough_lines4 ==='):].strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis')

"""Isolated Gowin mapping; no board/timing claims."""
import tempfile,subprocess,json
from test_hsv_color import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='hsv_synth_') as td:
 for w,h in ((16,16),(31,33),(65536,1)):
  script=f'read_verilog {(ROOT/"rgb_hsv_full_stream.v").as_posix()}; chparam -set WIDTH {w} -set HEIGHT {h} rgb_hsv_full_stream; synth_gowin -top rgb_hsv_full_stream; check -assert; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=td,capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
  results.append({'width':w,'height':h,'stat':p.stdout[p.stdout.rfind('=== rgb_hsv_full_stream ==='):].strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis')

"""Isolated Gowin mapping; retain statistics only, never intermediate netlists."""
import tempfile,subprocess,json
from test_hog import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='hog_synth_') as temporary:
 for bits,w,h,cw,ch in ((8,32,32,8,8),(12,64,48,8,8)):
  script=f'read_verilog {(ROOT/"hog_l1_9.v").as_posix()}; chparam -set BITS {bits} -set WIDTH {w} -set HEIGHT {h} -set CELL_W {cw} -set CELL_H {ch} hog_l1_9; synth_gowin -top hog_l1_9; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  results.append({'bits':bits,'width':w,'height':h,'cell':[cw,ch],'stat':p.stdout[p.stdout.rfind('=== hog_l1_9 ==='):].strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis')

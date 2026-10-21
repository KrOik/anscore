"""Isolated mapping and CHECK; generated netlists remain temporary."""
import tempfile,subprocess,json
from test_jpeg_color_mcu import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='jpeg_color_mcu_synth_') as temporary:
 for w,h in ((16,16),(31,33),(65536,1)):
  script=f'read_verilog {(ROOT/"jpeg_color_mcu.v").as_posix()}; chparam -set WIDTH {w} -set HEIGHT {h} jpeg_color_mcu; synth_gowin -top jpeg_color_mcu; check -assert; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  stat=p.stdout[p.stdout.rfind('=== jpeg_color_mcu ==='):].strip()
  if any(cell in stat for cell in ('MULT9X9','MULT18X18','MULT36X36')):raise AssertionError('unexpected DSP use')
  results.append({'width':w,'height':h,'check':'PASS','stat':stat})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis and CHECK')


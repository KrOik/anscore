"""Isolated technology mapping, no timing or hardware claim."""
import subprocess,json,tempfile
from test_autofocus import ROOT
result=[]
with tempfile.TemporaryDirectory(prefix='af_synth_'):
 for pw,mw in ((6,16),(12,24)):
  script=f'read_verilog {(ROOT/"contrast_af_controller.v").as_posix()}; chparam -set POS_W {pw} -set METRIC_W {mw} contrast_af_controller; synth_gowin -top contrast_af_controller; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],text=True,capture_output=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
  result.append({'position_bits':pw,'metric_bits':mw,'stat':p.stdout[p.stdout.rfind('=== contrast_af_controller ==='):].strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS isolated synthesis')

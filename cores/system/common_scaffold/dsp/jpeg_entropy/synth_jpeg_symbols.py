"""Isolated JPEG symbolization resource mapping; no timing or board claim."""
import tempfile,subprocess,json
from test_jpeg_symbols import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='jpeg_symbol_synth_'):
 for cw,components in ((12,1),(16,3)):
  script=f'read_verilog {(ROOT/"jpeg_baseline_symbols.v").as_posix()}; chparam -set COEFF_W {cw} -set COMPONENTS {components} jpeg_baseline_symbols; synth_gowin -top jpeg_baseline_symbols; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
  results.append({'coefficient_bits':cw,'components':components,'stat':p.stdout[p.stdout.rfind('=== jpeg_baseline_symbols ==='):].strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis')

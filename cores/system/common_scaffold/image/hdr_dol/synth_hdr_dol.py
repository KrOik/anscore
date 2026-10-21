"""Resource mapping only: no timing or board claim."""
import tempfile,subprocess,json
from test_hdr_dol import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='hdr_dol_synth_'):
 for module in ('raw_dol2_demux','raw_hdr2_merge'):
  script=f'read_verilog {(ROOT/"raw_hdr_dol.v").as_posix()}; chparam -set BITS 12 -set WIDTH 64 -set HEIGHT 33 {module}; synth_gowin -top {module}; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],text=True,capture_output=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
  results.append({'module':module,'bits':12,'width':64,'height':33,'stat':p.stdout[p.stdout.rfind('=== '+module+' ==='):].strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synth')

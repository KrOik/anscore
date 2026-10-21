"""Map complete FFT/crosspower/sqrt/divide/IFFT core and all three RAM banks."""
import tempfile,subprocess,json,hashlib
from run_tests import ROOT
results=[]
for n in (8,16,32):
 with tempfile.TemporaryDirectory(prefix='phase_synth_') as td:
  script=f'''read_verilog {(ROOT/'phase_correlation_frame.v').as_posix()};
chparam -set SIDE {n} -set TWIDDLE_FILE "{(ROOT/'twiddle.mem').as_posix()}" phase_correlation_frame;
synth_gowin -top phase_correlation_frame; check -assert; stat'''
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=ROOT,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  results.append({'side':n,'stat':p.stdout[p.stdout.rfind('=== phase_correlation_frame ==='):].strip()})
result={'status':'PASS','rtl_sha256':hashlib.sha256((ROOT/'phase_correlation_frame.v').read_bytes()).hexdigest(),'geometries':results}
(ROOT/'synthesis_result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))

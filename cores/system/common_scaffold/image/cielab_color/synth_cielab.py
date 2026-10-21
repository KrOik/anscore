"""Map the complete converter, including both synchronous ROMs."""
import json,subprocess,tempfile,hashlib
from run_tests import ROOT
results=[]
for w,h in ((16,16),(31,33),(65536,1)):
 with tempfile.TemporaryDirectory(prefix='cielab_synth_') as temporary:
  # Absolute ROM parameters make all retained working files independent of cwd.
  script=f'''read_verilog { (ROOT/'rgb_cielab_stream.v').as_posix() };
chparam -set WIDTH {w} -set HEIGHT {h} -set DECODE_FILE "{(ROOT/'decode.mem').as_posix()}" -set NONLINEAR_FILE "{(ROOT/'nonlinear.mem').as_posix()}" rgb_cielab_stream;
synth_gowin -top rgb_cielab_stream; check -assert; stat'''
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=ROOT,capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
  results.append({'width':w,'height':h,'stat':p.stdout[p.stdout.rfind('=== rgb_cielab_stream ==='):].strip()})
result={'status':'PASS','rtl_sha256':hashlib.sha256((ROOT/'rgb_cielab_stream.v').read_bytes()).hexdigest(),'geometries':results}
(ROOT/'synthesis_result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))

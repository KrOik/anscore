"""Isolated Gowin resource mapping; generated products stay temporary."""
import tempfile,subprocess,json
from test_sauvola import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='sauvola_synth_') as temporary:
 for bits,w,h,radius,k,r in ((8,32,32,1,51,128),(12,64,48,7,256,2048)):
  script=f'read_verilog {(ROOT/"sauvola_frame.v").as_posix()}; chparam -set BITS {bits} -set WIDTH {w} -set HEIGHT {h} -set RADIUS {radius} -set K_Q8 {k} -set R {r} sauvola_frame; synth_gowin -top sauvola_frame; check -assert; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  stat=p.stdout[p.stdout.rfind('=== sauvola_frame ==='):].strip()
  if any(cell in stat for cell in ('MULT9X9','MULT18X18','MULT36X36')):raise AssertionError('unexpected DSP use')
  results.append({'bits':bits,'width':w,'height':h,'radius':radius,'k_q8':k,'r':r,'check':'PASS','stat':stat})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis and CHECK')

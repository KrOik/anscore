"""Isolated mapping and CHECK; only small statistics persist."""
import tempfile,subprocess,json
from test_histogram_match import ROOT
results=[]
with tempfile.TemporaryDirectory(prefix='histmatch_synth_') as temporary:
 for bits,w,h,cw in ((8,32,32,16),(12,64,48,16)):
  script=f'read_verilog {(ROOT/"histogram_match_frame.v").as_posix()}; chparam -set BITS {bits} -set WIDTH {w} -set HEIGHT {h} -set REF_COUNT_W {cw} histogram_match_frame; synth_gowin -top histogram_match_frame; check -assert; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],cwd=temporary,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  stat=p.stdout[p.stdout.rfind('=== histogram_match_frame ==='):].strip()
  if any(cell in stat for cell in ('MULT9X9','MULT18X18','MULT36X36')):raise AssertionError('unexpected DSP use')
  results.append({'bits':bits,'width':w,'height':h,'reference_count_bits':cw,'check':'PASS','stat':stat})
(ROOT/'synthesis_result.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS isolated synthesis and CHECK')

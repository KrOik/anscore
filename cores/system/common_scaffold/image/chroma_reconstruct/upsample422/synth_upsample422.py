"""Isolated mapping; temporary netlists/log removed, small statistics retained."""
import os,subprocess,json,tempfile
from test_upsample422 import ROOT
result=[]
with tempfile.TemporaryDirectory(prefix='chroma422_synth_') as td:
 for bits,w,h in ((8,64,48),(10,1920,1080)):
  script=f'read_verilog { (ROOT/"chroma_upsample422.v").as_posix() }; chparam -set BITS {bits} -set WIDTH {w} -set HEIGHT {h} chroma_upsample422; synth_gowin -top chroma_upsample422; stat'
  p=subprocess.run(['yosys','-Q','-T','-p',script],text=True,capture_output=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr[-1000:])
  section=p.stdout[p.stdout.rfind('=== chroma_upsample422 ==='):]
  result.append({'bits':bits,'width':w,'height':h,'stat':section.strip()})
(ROOT/'synthesis_result.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS isolated synthesis',len(result))

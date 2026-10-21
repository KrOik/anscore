from pathlib import Path
import hashlib,json,re,sys,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
rtl=HERE/'seam_find.sv';sha=hashlib.sha256(rtl.read_bytes()).hexdigest()
for name in ('evidence.json','error_evidence.json'):
 e=json.loads((HERE/name).read_text());assert e['status']=='PASS' and e['rtl_sha256']==sha
with tempfile.TemporaryDirectory(prefix='seam_synth_') as td:
 text=execute(['yosys','-p',f'read_verilog -sv {rtl.as_posix()}; synth_gowin -top seam_find -noalu -nodsp; check -assert; stat'],td,Path(td)/'full.log',timeout=600)
 summary=text.rsplit('=== seam_find ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',summary,re.M)}
 result=dict(status='PASS',cells=cells,lut=sum(cells.get(f'LUT{i}',0) for i in range(1,5)),
  ff=sum(n for k,n in cells.items() if k.startswith('DFF')),
  ram={k:n for k,n in cells.items() if 'RAM' in k or k.startswith(('SP','DP','SDP'))},
  dsp=sum(n for k,n in cells.items() if any(t in k for t in ('MULT','DSP','PADD'))),
  flow='synth_gowin -noalu -nodsp; check -assert',rtl_sha256=sha,board=False,pnr=False)
 (HERE/'synthesis.log').write_text('CHECK -assert PASS\n'+summary)
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result)

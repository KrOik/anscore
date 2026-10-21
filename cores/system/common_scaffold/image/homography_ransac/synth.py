from pathlib import Path
import hashlib,json,re,sys,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
evidence=json.loads((HERE/'evidence.json').read_text())
rtl=HERE/'homography_ransac.sv'
assert evidence['status']=='PASS' and evidence['rtl_sha256']==hashlib.sha256(rtl.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='homography_synth_') as td:
 text=execute(['yosys','-p',f'read_verilog -sv {rtl.as_posix()}; synth_gowin -top homography_ransac -noalu -nodsp; check -assert; stat'],td,Path(td)/'full.log',timeout=600)
 summary=text.rsplit('=== homography_ransac ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',summary,re.M)}
 result=dict(status='PASS',cells=cells,lut=sum(cells.get(f'LUT{i}',0) for i in range(1,5)),
  ff=sum(n for k,n in cells.items() if k.startswith('DFF')),
  ram={k:n for k,n in cells.items() if 'RAM' in k or k.startswith(('SP','DP','SDP'))},
  dsp=sum(n for k,n in cells.items() if any(t in k for t in ('MULT','DSP','PADD'))),
  flow='synth_gowin -noalu -nodsp; check -assert',rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(),board=False,pnr=False)
 (HERE/'synthesis.log').write_text('CHECK -assert PASS\n'+summary)
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result)

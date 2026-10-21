from pathlib import Path
import hashlib,json,re,tempfile
from test_pipeline import HERE,PACKAGE,SOURCES,execute
hashes={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
for name in ('evidence.json','error_evidence.json'):
 e=json.loads((HERE/name).read_text());assert e['status']=='PASS' and e['sources']==hashes
with tempfile.TemporaryDirectory(prefix='seam_multiband_synth_') as td:
 script='read_verilog -sv '+' '.join(p.as_posix() for p in SOURCES)+'; synth_gowin -top seam_multiband_blend -noalu -nodsp; check -assert; stat'
 text=execute(['yosys','-p',script],td,Path(td)/'full.log',timeout=600)
 summary=text.rsplit('=== design hierarchy ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',summary,re.M)}
 result=dict(status='PASS',scope='complete seam_find + multiband_blend + synchronous pair replay hierarchy',cells=cells,
  lut=sum(cells.get(f'LUT{i}',0) for i in range(1,5)),ff=sum(n for k,n in cells.items() if k.startswith('DFF')),
  ram={k:n for k,n in cells.items() if 'RAM' in k or k.startswith(('SP','DP','SDP'))},
  dsp=sum(n for k,n in cells.items() if any(t in k for t in ('MULT','DSP','PADD'))),
  flow='synth_gowin -noalu -nodsp; check -assert',sources=hashes,board=False,pnr=False)
 assert hashes=={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'synthesis.log').write_text('Full hierarchy CHECK -assert PASS\n'+summary)
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result)

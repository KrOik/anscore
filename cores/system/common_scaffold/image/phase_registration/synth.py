import hashlib,json,re,shutil,tempfile
from pathlib import Path
from test_registration import HERE,PACKAGE,PHASE,SOURCES,execute
hashes={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES+[PHASE/'twiddle.mem']}
for name in ('evidence.json','error_evidence.json'):
 e=json.loads((HERE/name).read_text());assert e['status']=='PASS' and e['sources']==hashes
results=[]
for side in (8,16,32):
 with tempfile.TemporaryDirectory(prefix=f'phase_registration_synth_{side}_') as td:
  td=Path(td);shutil.copyfile(PHASE/'twiddle.mem',td/'twiddle.mem')
  script='read_verilog -sv '+' '.join(p.as_posix() for p in SOURCES)+f'; chparam -set SIDE {side} phase_registration; synth_gowin -top phase_registration -nodsp; check -assert; stat'
  text=execute(['yosys','-p',script],td,td/'full.log',timeout=600)
  summary=text.rsplit('=== design hierarchy ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',summary,re.M)}
  lut=sum(cells.get(f'LUT{i}',0) for i in range(1,5));alu=cells.get('ALU',0)
  mux=sum(n for k,n in cells.items() if k.startswith('MUX'))
  result=dict(side=side,status='PASS',cells=cells,lut1_to_4=lut,alu=alu,lut_plus_alu=lut+alu,
   lut_plus_alu_plus_mux=lut+alu+mux,ff=sum(n for k,n in cells.items() if k.startswith('DFF')),
   ram={k:n for k,n in cells.items() if 'RAM' in k or k.startswith(('SP','DP','SDP'))},
   dsp=sum(n for k,n in cells.items() if any(t in k for t in ('MULT','DSP','PADD'))))
  assert result['lut_plus_alu_plus_mux']<=15000 and result['dsp']<=4
  (HERE/f'synthesis_{side}.log').write_text('Complete hierarchy CHECK -assert PASS\n'+summary)
  results.append(result);print(result,flush=True)
assert hashes=={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES+[PHASE/'twiddle.mem']}
(HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=hashes,geometries=results,
 flow='synth_gowin -nodsp; check -assert; stat; ALU and mux included in conservative budget',board=False,pnr=False),indent=2)+'\n')

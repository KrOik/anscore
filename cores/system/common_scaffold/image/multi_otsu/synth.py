import json,re,tempfile
from test_multi_otsu import HERE,RTL,execute,hashes
h=hashes()
for name in ('evidence.json','error_evidence.json'):
 e=json.loads((HERE/name).read_text());assert e['status']=='PASS' and e['sources']==h
with tempfile.TemporaryDirectory(prefix='multiotsu_synth_') as d:
 from pathlib import Path
 d=Path(d)
 script=f'read_verilog -sv {RTL.as_posix()}; synth_gowin -top multi_otsu -nodsp; check -assert; stat'
 text=execute(['yosys','-p',script],d,d/'full.log',timeout=600)
 summary=text.rsplit('=== multi_otsu ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',summary,re.M)}
 lut=sum(cells.get(f'LUT{i}',0) for i in range(1,5));alu=cells.get('ALU',0);mux=sum(n for k,n in cells.items() if k.startswith('MUX'))
 result=dict(status='PASS',sources=h,max_side=32,cells=cells,lut1_to_4=lut,alu=alu,lut_plus_alu_plus_mux=lut+alu+mux,ff=sum(n for k,n in cells.items() if k.startswith('DFF')),ram={k:n for k,n in cells.items() if 'RAM' in k or k.startswith(('SP','DP','SDP'))},dsp=sum(n for k,n in cells.items() if any(t in k for t in ('MULT','DSP','PADD'))),flow='synth_gowin -nodsp; check -assert; stat; ALU and mux included',board=False,pnr=False)
 assert cells and result['lut_plus_alu_plus_mux']<=15000 and result['dsp']<=4
 (HERE/'synthesis.log').write_text('Complete standalone hierarchy CHECK -assert PASS\n'+summary)
 assert h==hashes()
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result,flush=True)

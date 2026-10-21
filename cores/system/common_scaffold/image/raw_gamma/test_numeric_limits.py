from pathlib import Path
import sys,tempfile,json
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
bad=[{'BITS':9},{'OUT_BITS':9},{'INDEX_BITS':0},{'INDEX_BITS':9},{'BITS':8,'INDEX_BITS':9},{'WIDTH':0},{'HEIGHT':0},{'WIDTH':4097},{'HEIGHT':4097},{'WIDTH':4096,'HEIGHT':17}]
rows=[]
for i,p in enumerate(bad):
 with tempfile.TemporaryDirectory(prefix='gamma_parameter_') as td:
  tb=Path(td)/'tb.sv';out=Path(td)/'a.vvp'
  tb.write_text('module tb; raw_gamma #('+','.join('.%s(%d)'%(k,v) for k,v in p.items())+') dut(); initial #2 $finish; endmodule')
  execute(['iverilog','-g2012','-s','tb','-o',str(out),str(H/'raw_gamma.sv'),str(tb)],ROOT,H/'parameter_compile.log')
  try: execute(['vvp',str(out)],ROOT,H/'parameter_last_rejection.log');raise AssertionError('accepted illegal parameter')
  except RuntimeError: rows.append({'parameters':p,'rejected':True})
for b in (8,10,12):
 m=(1<<b)-1
 for idx in range(1,min(b,8)+1):
  k=1<<idx
  for p in range(m+1):
   j=min(k-1,p*k//m);fast=k-1 if p==m else p>>(b-idx)
   assert fast==j and 0<=p*k-j*m<=m
 for o in (8,10,12):
  assert ((1<<o)-1)*m+m//2 < 1<<(b+o+1)
(H/'parameter_evidence.json').write_text(json.dumps({'result':'PASS','invalid_parameters':rows,'index_proof':'exhaustive all legal BITS/INDEX_BITS and input codes','numerator_width':'BITS+OUT_BITS+1 covers maximum blend plus rounding'},indent=2)+'\n')
print('PASS parameters: 10 rejects; exhaustive segment-index/endpoint and numerator bounds')

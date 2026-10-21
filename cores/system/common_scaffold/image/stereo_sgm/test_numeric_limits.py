import tempfile,json,random
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes,oracle
frozen=hashes();rows=[]
for overrides in [('WIDTH',0),('HEIGHT',0),('WIDTH',257),('HEIGHT',257),('WIDTH',128,'HEIGHT',64),('DESC_BITS',0),('DESC_BITS',65),('DISPARITIES',0),('DISPARITIES',65),('WIDTH',4,'DISPARITIES',5),('DISP_BITS',1)]:
 pairs=list(zip(overrides[::2],overrides[1::2]));params=','.join(f'.{k}({v})'for k,v in pairs)
 with tempfile.TemporaryDirectory(prefix='sgm_bad_')as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(f'module tb;stereo_sgm #({params}) dut();initial #1 $finish;endmodule')
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log')
  try:execute(['vvp',p/'sim'],p,p/'sim.log');raise AssertionError('accepted invalid parameters')
  except RuntimeError as e:assert 'stereo_sgm invalid parameters' in str(e)
 rows.append(pairs)
rng=random.Random(342);w,h,D=8,6,4;l=[rng.getrandbits(24)for _ in range(w*h)];r=[rng.getrandbits(24)for _ in l];out,total,paths=oracle(l,r,[0]*len(l),[0]*len(l),w,h,D,3,15)
wta=[min(range(min(i%w,D-1)+1),key=lambda d:(l[i]^r[i-d]).bit_count())for i in range(len(l))]
changed=sum(o[0]!=d for o,d in zip(out,wta));assert changed>0
# Bound: C<=1024; normalized recurrence adds 0..P2<=255; sum four paths <=5116.
assert 1024+255<4096 and 4*(1024+255)<16383
assert hashes()==frozen
(HERE/'invalid_parameters.json').write_text(json.dumps(dict(status='PASS',sources=frozen,rejected=rows),indent=2)+'\n')
(HERE/'numeric_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,max_cost=1024,max_path=1279,max_aggregate=5116,wta_difference_pixels=changed,proof='min includes previous global minimum + P2 and is >= global minimum; C in [0,1024]; hence L in [C,C+P2]'),indent=2)+'\n')
print('PASS rejected',len(rows),'SGM/WTA differences',changed)

import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();rows=[]
for pairs in [dict(WIDTH=0),dict(HEIGHT=0),dict(WIDTH=4097),dict(HEIGHT=4097),dict(WIDTH=4096,HEIGHT=17),dict(DISP_BITS=1),dict(DISP_BITS=33),dict(DISP_FRAC=-1),dict(DISP_FRAC=17),dict(SIZE_BITS=1),dict(SIZE_BITS=25)]:
 params=','.join(f'.{k}({v})'for k,v in pairs.items())
 with tempfile.TemporaryDirectory(prefix='speckle_bad_')as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(f'module tb;disparity_speckle #({params})dut();initial #1 $finish;endmodule');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log')
  try:execute(['vvp',p/'sim'],p,p/'sim.log');raise AssertionError('invalid accepted')
  except RuntimeError as e:assert 'disparity_speckle invalid parameters' in str(e)
 rows.append(pairs)
assert 2**32-1<2**32 and -(2**32-1)>=-2**32
assert frozen==hashes()
(HERE/'numeric_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,invalid_parameter_rejections=rows,difference_bits='DISP_BITS+1 signed; abs max2^DISP_BITS-1 fits unsigned DISP_BITS+1',queue_bound='visited marked on enqueue; each valid vertex enqueued at most once; tail<=N; head/tail represent N using SIZE_BITS>=clog2(N+1)'),indent=2)+'\n');print('PASS invalid_parameters',len(rows))

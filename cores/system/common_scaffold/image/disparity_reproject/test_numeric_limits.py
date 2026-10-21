import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();rows=[]
for pairs in [dict(WIDTH=0),dict(HEIGHT=0),dict(WIDTH=4097),dict(HEIGHT=4097),dict(WIDTH=4096,HEIGHT=4096),dict(DISP_BITS=1),dict(DISP_BITS=25),dict(DISP_FRAC=-1),dict(DISP_FRAC=13),dict(Q_BITS=1),dict(Q_BITS=33),dict(Q_FRAC=-1),dict(Q_FRAC=29),dict(OUT_BITS=1),dict(OUT_BITS=33),dict(OUT_FRAC=-1),dict(OUT_FRAC=17)]:
 params=','.join(f'.{k}({v})'for k,v in pairs.items())
 with tempfile.TemporaryDirectory(prefix='reproject_bad_')as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(f'module tb;disparity_reproject #({params})dut();initial #1 $finish;endmodule')
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log')
  try:execute(['vvp',p/'sim'],p,p/'sim.log');raise AssertionError('invalid parameters accepted')
  except RuntimeError as e:assert 'disparity_reproject invalid parameters' in str(e)
 rows.append(pairs)
# Exact worst-case homogeneous absolute bound under all permitted widths/formats.
q=2**31;vmax=4095*2**12;dmax=2**23;one=2**12
hbound=q*(vmax+vmax+dmax+one)
assert hbound<2**57 and hbound*2**16<2**73 and 2*hbound<2**64
assert frozen==hashes()
(HERE/'numeric_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,invalid_parameter_rejections=rows,max_homogeneous_abs=hbound,max_shifted_numerator_abs=hbound*2**16,proof='sum abs(Q_ij*vector_j); signed64 H and unsigned96 numerator safely cover permitted ranges; signed negative output limit handled separately'),indent=2)+'\n')
print('PASS invalid',len(rows),'homogeneous bound',hbound)

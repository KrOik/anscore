import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();rows=[]
for pairs in [dict(WIDTH=0),dict(HEIGHT=0),dict(WIDTH=4097),dict(HEIGHT=4097),dict(WIDTH=4096,HEIGHT=17),dict(BITS=9),dict(GRID_WIDTH=1),dict(GRID_WIDTH=10),dict(GRID_HEIGHT=1),dict(GRID_HEIGHT=10),dict(GAIN_BITS=1),dict(GAIN_BITS=25),dict(GAIN_FRAC=-1),dict(GAIN_FRAC=21)]:
 params=','.join(f'.{k}({v})'for k,v in pairs.items())
 with tempfile.TemporaryDirectory(prefix='lsc_bad_')as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(f'module tb;lens_shading #({params})dut();initial #1 $finish;endmodule');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log')
  try:execute(['vvp',p/'sim'],p,p/'sim.log');raise AssertionError('invalid parameters accepted')
  except RuntimeError as e:assert 'lens_shading invalid parameters' in str(e)
 rows.append(pairs)
weight=4095**2;weighted=weight*((1<<24)-1);numerator=weighted*((1<<12)-1);denominator=weight*(1<<20)
assert weight<1<<24 and weighted<1<<48 and numerator<1<<60 and denominator<1<<44
# The four bilinear integer weights sum exactly DX*DY, including closed right/bottom endpoints.
checks=0
for dx in range(1,35):
 for dy in range(1,27):
  for rx in range(dx+1):
   for ry in (0,dy//2,dy):
    assert (dx-rx)*(dy-ry)+rx*(dy-ry)+(dx-rx)*ry+rx*ry==dx*dy;checks+=1
assert frozen==hashes()
(HERE/'numeric_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,invalid_parameter_rejections=rows,max_weight=weight,max_weighted_gain=weighted,max_raw_numerator=numerator,max_denominator=denominator,weight_partition_checks=checks,proof='four weights partition DX*DY; unsigned64 sum and RAW product bounded below2^60, denominator below2^44; multiply operands for weight/gain/raw each fit unsigned32'),indent=2)+'\n');print('PASS invalid_parameters',len(rows),'partition_checks',checks)

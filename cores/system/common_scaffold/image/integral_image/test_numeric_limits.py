from pathlib import Path
import hashlib,json,tempfile
from run_tests import H,ROOT,RTL,execute,run_profile
bad=[dict(WIDTH=0),dict(HEIGHT=0),dict(WIDTH=4097),dict(HEIGHT=4097),dict(WIDTH=4096,HEIGHT=17),dict(BITS=9),dict(BITS=16)]
rows=[]
for p in bad:
 with tempfile.TemporaryDirectory(prefix='integral_parameter_')as td:
  d=Path(td);(d/'tb.sv').write_text('module tb;integral_image #('+','.join('.%s(%d)'%(k,v)for k,v in p.items())+')dut();initial #2 $finish;endmodule')
  execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,d/'compile.log')
  try:execute(['vvp',d/'a.vvp'],ROOT,d/'run.log');raise AssertionError('illegal profile accepted')
  except RuntimeError:rows.append(p)
bounds=[]
for b in (8,10,12):
 m=(1<<b)-1;n=65536;s=n*m;sq=n*m*m
 assert s<1<<32 and sq<1<<40 and n<1<<32
 bounds.append(dict(bits=b,max_pixels=n,max_sum=s,max_sqsum=sq))
# Max supported actual sensor pixels and longest supported axis, full-max data.
# Query full frame/random rectangles without generating 130K per-cell transactions.
profiles=[run_profile(256,256,12,[[[4095]*256 for _ in range(256)]],False),
          run_profile(4096,1,12,[[[4095]*4096]],False),
          run_profile(1,4096,10,[[[1023]for _ in range(4096)]],False)]
(H/'numeric_result.json').write_text(json.dumps(dict(result='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),rejected_parameters=rows,bounds=bounds,profiles=profiles),indent=2)+'\n')
print('PASS bounds, 7 illegal profiles, maximum frame and maximum axes')

from pathlib import Path
from fractions import Fraction
import hashlib,json,random,tempfile
from run_tests import H,ROOT,execute,nearest,run_profile
bad=[dict(WIDTH=0),dict(HEIGHT=0),dict(WIDTH=4097),dict(HEIGHT=4097),dict(WIDTH=4096,HEIGHT=17),dict(BITS=9),dict(BITS=16)]
rows=[]
for p in bad:
 with tempfile.TemporaryDirectory(prefix='raw_awb_parameter_')as td:
  d=Path(td);(d/'tb.sv').write_text('module tb;raw_white_balance #('+','.join('.%s(%d)'%(k,v)for k,v in p.items())+')dut();initial #2 $finish;endmodule')
  execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',H/'raw_white_balance.sv',d/'tb.sv'],ROOT,d/'compile.log')
  try:execute(['vvp',d/'a.vvp'],ROOT,d/'run.log');raise AssertionError('illegal profile accepted')
  except RuntimeError:rows.append(p)
# Independent conservative bounds: even deliberately ignoring Bayer 1/4 occupancy,
# all sums <= N*(2^BITS-1), all counts <= N. Rounded numerator <2^57.
bounds=[]
for b in (8,10,12):
 n=65536;m=(1<<b)-1;s=n*m;den=s*n;num=(s*n<<12)+(den//2)
 assert s<1<<28 and den<1<<44 and num<1<<57
 assert m*65535+2048<1<<29
 bounds.append(dict(bits=b,max_conservative_sum=s,max_denominator=den,max_rounded_numerator=num))
# Exercise maximum supported full-frame geometry in the actual RTL, hardware gains
# from real captured 65536 pixels. R/B mean1 vs pooled-green4095 hits gain clip.
c=dict(pattern=0,auto=True,roi=[0,0,255,255],gate=[0,4095],bounds=[0,65535],manual=[4096]*4,
 data=[([1,4095,4095,1][((i//256)&1)*2+(i%256&1)])for i in range(65536)])
profile=run_profile(256,256,12,[c])
e=dict(result='PASS',rtl_sha256=hashlib.sha256((H/'raw_white_balance.sv').read_bytes()).hexdigest(),rejected_parameters=rows,bounds=bounds,maximum_frame_profile=profile)
(H/'numeric_result.json').write_text(json.dumps(e,indent=2)+'\n')
print('PASS numeric limits: 7 rejects, 64-bit proof, maximum frame 65536 pixels')

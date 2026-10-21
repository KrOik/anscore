"""All 16-bit root square boundaries; expected floor from Python math.isqrt."""
import datetime,hashlib,json,math,os,random,shutil,subprocess
from pathlib import Path
H=Path(__file__).resolve().parent;ROOT=H.parents[5]
out=H/'evidence'/datetime.datetime.now().strftime('sqrt_%Y%m%d_%H%M%S_%f');out.mkdir(parents=True)
values={0,0xffffffff}
for q in range(65536):
 for d in (-1,0,1):
  x=q*q+d
  if 0<=x<=0xffffffff:values.add(x)
rng=random.Random(20260925);values.update(rng.randrange(1<<32) for _ in range(10000))
(out/'vectors.txt').write_text(''.join(f'{x:08x} {math.isqrt(x):04x}\n' for x in sorted(values)))
tb='''module tb;
reg clk=0;always #5 clk=~clk;
statistics_stream dut(.clk(clk),.rst_n(1'b0),.s_tdata(16'b0),.s_tvalid(1'b0),.m_tready(1'b1),.cfg_valid(1'b0),.cfg_block(1'b0),.cfg_log2(4'b0),.cfg_scale(5'b0),.cfg_threshold(32'b0));
integer f,n,count=0;reg [31:0] x;reg [15:0] expected;reg [81:0] a,b,c,d;
initial begin
f=$fopen("vectors.txt","r");
while(!$feof(f))begin
n=$fscanf(f,"%h %h\\n",x,expected);
if(n!=2)$fatal(1,"fixture");
a=dut.root_four(34'b0,16'b0,x);
b=dut.root_four(a[81:48],a[47:32],a[31:0]);
c=dut.root_four(b[81:48],b[47:32],b[31:0]);
d=dut.root_four(c[81:48],c[47:32],c[31:0]);
if(d[47:32]!==expected)$fatal(1,"sqrt %h got %h expected %h",x,d[47:32],expected);
count=count+1;
end
$display("PASS sqrt boundaries=%0d",count);$finish;
end
endmodule
'''
(out/'tb.sv').write_text(tb);shutil.copy2(H/'statistics_stream.sv',out/'statistics_stream.sv');shutil.copy2(__file__,out/'test_sqrt_boundaries.py')
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
for cmd,name in [([str(tool/'bin/iverilog.exe'),'-g2012','-s','tb','-o','test.vvp','statistics_stream.sv','tb.sv'],'compile.log'),([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')]:
 r=subprocess.run(cmd,cwd=out,env=env,text=True,capture_output=True);(out/name).write_text(r.stdout+r.stderr)
 if r.returncode:raise AssertionError(name)
(out/'summary.json').write_text(json.dumps(dict(status='PASS',cases=len(values),coverage='q*q-1/q*q/q*q+1 for every unsigned16 q plus seeded random unsigned32 radicands',rtl_sha256=hashlib.sha256((H/'statistics_stream.sv').read_bytes()).hexdigest()),indent=2))
print('SQRT BOUNDARIES PASS',out)

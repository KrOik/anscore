from pathlib import Path
import random,tempfile,subprocess,sys,shutil,json,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[3]/'integration'))
from tooling import tool_env
env=tool_env()
rng=random.Random(0x4e4c4d)
vectors=[(0,1),((1<<64)-1,1),((1<<64)-1,(1<<64)-1),(1,(1<<64)-1)]+[(rng.getrandbits(64),rng.getrandbits(64) or 1) for _ in range(256)]
checks=[]
for n,d in vectors:
 checks.append(f"@(negedge clk);dut.state=11;dut.div_quotient=64'h{n:016x};dut.div_denominator=64'h{d:016x};dut.div_remainder=0;dut.div_remaining=64;dut.div_normalize=0;repeat(320)@(posedge clk);#1;if(dut.div_quotient!==64'h{n//d:016x} || dut.div_remainder!==64'h{n%d:016x})$fatal(1, \"divider mismatch\");")
for ssd in [0,1,(1<<44)-1,1<<44,(1<<63),(1<<64)-1]:
 n=(ssd<<20)&((1<<64)-1);d=9*65535*65535
 checks.append(f"@(negedge clk);dut.state=8;dut.ssd=64'h{ssd:016x};dut.pr=1;dut.h=65535;dut.denominator=64\'d38653526025;@(posedge clk);#1;wait(dut.state==19);#1;if(dut.div_quotient!==64'h{min(255,n//d):016x})$fatal(1, \"shift truncation mismatch\");")
for weighted,weight in [((1<<64)-1,3),((1<<64)-2,9),(123456,100)]:
 n=(weighted+(weight>>1))&((1<<64)-1)
 checks.append(f"@(negedge clk);dut.state=9;dut.weighted_sum=64'h{weighted:016x};dut.weight_sum={weight};@(posedge clk);#1;wait(dut.state==13);#1;if(dut.div_quotient!==64'h{min(255,n//weight):016x})$fatal(1, \"normalization truncation mismatch\");")
for a,b in vectors:
 checks.append(f"@(negedge clk);dut.state=17;dut.mul_a=64'h{a:016x};dut.mul_b=64'h{b:016x};dut.mul_acc=0;dut.mul_remaining=64;dut.mul_patch=1;dut.mul_word=0;dut.mul_carry=0;repeat(256)@(posedge clk);#1;if(dut.denominator!==64'h{(a*b)&((1<<64)-1):016x})$fatal(1, \"multiply truncation mismatch\");")
for numerator,denominator in [(0,0),(0,1),(1<<20,4097),(1<<20,4096),(1<<20,4095),((1<<64)-(1<<20),1),((1<<64)-(1<<20),(1<<64)-1)]:
 ssd=numerator>>20;expect=0 if denominator==0 else min(255,numerator//denominator)
 checks.append(f"@(negedge clk);dut.state=8;dut.ssd=64'h{ssd:016x};dut.denominator=64'h{denominator:016x};@(posedge clk);#1;wait(dut.state==19);#1;if(dut.div_quotient!==64'h{expect:016x})$fatal(1, \"index threshold mismatch\");")
for weighted,weight in [(0,0),(0,1),(255,1),(256,1),(257,1),(255*123-61,123),(256*123-61,123),((1<<64)-1,(1<<64)-1)]:
 n=(weighted+(weight>>1))&((1<<64)-1);expect=0 if weight==0 else min(255,n//weight)
 checks.append(f"@(negedge clk);dut.state=9;dut.weighted_sum=64'h{weighted:016x};dut.weight_sum=64'h{weight:016x};@(posedge clk);#1;wait(dut.state==13);#1;if(dut.div_quotient!==64'h{expect:016x})$fatal(1, \"normalization threshold mismatch\");")
tb='module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0;img_filter_nlm_serial_engine dut(.clk(clk),.rst_n(rst_n),.clk_en(1\'b1));initial begin #2;rst_n=1;'+''.join(checks)+'$display("DIVIDER PASS division=284 multiply=260");$finish;end endmodule'
with tempfile.TemporaryDirectory(prefix='nlm_divider_') as temp:
 t=Path(temp);(t/'tb.v').write_text(tb)
 subprocess.run([shutil.which('iverilog',path=env['PATH']),'-g2012','-s','tb','-o',str(t/'a.vvp'),str(t/'tb.v'),str(HERE/'candidate_v8/img_filter_nlm_serial_engine.v'),str(HERE.parents[3]/'image/filters/rtl/img_filter_exp_weight.v')],check=True,env=env)
 subprocess.run([shutil.which('vvp',path=env['PATH']),str(t/'a.vvp')],check=True,env=env)

source=HERE/"candidate_v8/img_filter_nlm_serial_engine.v"
(HERE/"arithmetic_checks_v8_summary.json").write_text(json.dumps({"status":"PASS","division_checks":284,"multiplication_checks":260,"source_sha256":hashlib.sha256(source.read_bytes()).hexdigest()},indent=2)+"\n")

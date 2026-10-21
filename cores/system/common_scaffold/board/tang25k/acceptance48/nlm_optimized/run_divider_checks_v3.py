from pathlib import Path
import random,tempfile,subprocess,sys,shutil
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[3]/'integration'))
from tooling import tool_env
env=tool_env()
rng=random.Random(0x4e4c4d)
vectors=[(0,1),((1<<64)-1,1),((1<<64)-1,(1<<64)-1),(1,(1<<64)-1)]+[(rng.getrandbits(64),rng.getrandbits(64) or 1) for _ in range(256)]
checks=[]
for n,d in vectors:
 checks.append(f"@(negedge clk);dut.state=11;dut.div_quotient=64'h{n:016x};dut.div_denominator=64'h{d:016x};dut.div_remainder=0;dut.div_remaining=64;dut.div_normalize=0;repeat(64)@(posedge clk);#1;if(dut.div_quotient!==64'h{n//d:016x} || dut.div_remainder!==64'h{n%d:016x})$fatal(1, \"divider mismatch\");")
for ssd in [0,1,(1<<44)-1,1<<44,(1<<63),(1<<64)-1]:
 n=(ssd<<20)&((1<<64)-1);d=9*65535*65535
 checks.append(f"@(negedge clk);dut.state=8;dut.ssd=64'h{ssd:016x};dut.pr=1;dut.h=65535;@(posedge clk);repeat(64)@(posedge clk);#1;if(dut.div_quotient!==64'h{n//d:016x})$fatal(1, \"shift truncation mismatch\");")
for weighted,weight in [((1<<64)-1,3),((1<<64)-2,9),(123456,100)]:
 n=(weighted+(weight>>1))&((1<<64)-1)
 checks.append(f"@(negedge clk);dut.state=9;dut.weighted_sum=64'h{weighted:016x};dut.weight_sum={weight};@(posedge clk);repeat(64)@(posedge clk);#1;if(dut.div_quotient!==64'h{n//weight:016x})$fatal(1, \"normalization truncation mismatch\");")
tb='module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0;img_filter_nlm_serial_engine dut(.clk(clk),.rst_n(rst_n),.clk_en(1\'b1));initial begin #2;rst_n=1;'+''.join(checks)+'$display("DIVIDER PASS vectors=269 including9 launch/truncation cases");$finish;end endmodule'
with tempfile.TemporaryDirectory(prefix='nlm_divider_') as temp:
 t=Path(temp);(t/'tb.v').write_text(tb)
 subprocess.run([shutil.which('iverilog',path=env['PATH']),'-g2012','-s','tb','-o',str(t/'a.vvp'),str(t/'tb.v'),str(HERE/'candidate_v3/img_filter_nlm_serial_engine.v'),str(HERE.parents[3]/'image/filters/rtl/img_filter_exp_weight.v')],check=True,env=env)
 subprocess.run([shutil.which('vvp',path=env['PATH']),str(t/'a.vvp')],check=True,env=env)

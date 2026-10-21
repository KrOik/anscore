from pathlib import Path
import random,tempfile,json,sys
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[4]))
from integration.tooling import execute
r=random.Random(20261020)
v=[(a,b) for a in (-(1<<23),-1,0,1,(1<<23)-1) for b in (-32768,-1,0,1,32767)]
v += [(r.randrange(-(1<<23),1<<23),r.randrange(-32768,32768)) for _ in range(4096)]
lines=[]
for a,b in v:
 lines.append(f"@(negedge clk);dut.sample_q=24'h{a&0xffffff:06x};dut.coeff_q=16'h{b&65535:04x};dut.state=7;wait(dut.state==2);#1;if(dut.product_q!==40'h{(a*b)&((1<<40)-1):010x})$fatal(1,\"product mismatch\");")
tb="""module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0;dct8x8_serial_diag dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.cfg_valid(1'b0),.cfg_inverse(1'b0),.s_data(16'd0),.s_valid(1'b0),.m_ready(1'b1));initial begin repeat(3)@(negedge clk);rst_n=1;
"""+'\n'.join(lines)+f'\n$display("PASS PRODUCT {len(v)} exact signed24x16 vectors");$finish;end endmodule'
with tempfile.TemporaryDirectory(prefix='jpeg_product_') as d:
 q=Path(d);(q/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',q/'sim',H/'dct8x8_serial_diag.sv',q/'tb.sv'],q,H/'product_compile.log')
 text=execute(['vvp',q/'sim'],q,H/'product_simulation.log');assert 'PASS PRODUCT' in text;print(text)
(H/'product_regression_result.json').write_text(json.dumps(dict(status='PASS',vectors=len(v),oracle='Independent Python arbitrary-precision signed24 * signed16'),indent=2)+'\n')

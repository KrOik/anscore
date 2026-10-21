from pathlib import Path
import random,tempfile,sys,json
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H.parents[3]/'integration'));from tooling import execute
rng=random.Random(127110);cases=[]
with tempfile.TemporaryDirectory(prefix='a48_divider_') as t:
 for w,d in [(15,15),(16,16),(23,23),(40,16)]:
  p=Path(t)/f'w{w}d{d}';p.mkdir();vectors=[(0,1),((1<<w)-1,1),((1<<w)-1,(1<<d)-1),(0,0)]+[(rng.getrandbits(w),rng.getrandbits(d) or 1) for _ in range(128)]
  calls=''.join(f"run({w}'h{n:x},{w}'h{v:x},{w}'h{(n//v if v else 0):x});\n" for n,v in vectors)
  tb=p/'tb.v';tb.write_text("""module tb;localparam W="""+str(w)+",D="+str(d)+""";reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start=0;reg[W-1:0]n=0,den=1;wire done,error;wire[W-1:0]q;
geo_serial_divider #(.W(W),.D(D))dut(clk,rst_n,ce,start,n,den,done,error,q);
integer k,total=0;reg[31:0]rng=32'h12ab3456;
task run;input[W-1:0]a,b,g;begin
 @(negedge clk);ce=1;start=1;n=a;den=b;@(posedge clk);#1;@(negedge clk);start=0;k=0;
 while(!done)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[2:0]!=0;@(posedge clk);#1;@(negedge clk);k=k+1;if(k>W*3+10)$fatal(1,"timeout");end
 if(q!==g || error!==(b==0))$fatal(1,"division mismatch");total=total+1;ce=1;@(posedge clk);#1;
end endtask
initial begin repeat(3)@(posedge clk);@(negedge clk);rst_n=1;
"""+calls+'$display("DIVIDER PASS tests=%0d",total);$finish;end endmodule')
  binary=p/'sim.vvp';execute(['iverilog','-g2012','-s','tb','-o',binary,H/'geo_serial_divider.v',tb],H,H/f'divider_w{w}d{d}_compile.log');out=execute(['vvp',binary],H,H/f'divider_w{w}d{d}_simulation.log');assert 'DIVIDER PASS' in out;print(out.strip());cases.append({'width':w,'denominator_width':d,'tests':len(vectors)})
(H/'divider_regression_summary.json').write_text(json.dumps({'status':'PASS','cases':cases},indent=2))

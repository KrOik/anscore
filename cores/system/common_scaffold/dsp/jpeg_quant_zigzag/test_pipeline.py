from pathlib import Path
import sys,tempfile,random,json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE));sys.path.insert(0,str(HERE.parent/'dct8x8'));sys.path.insert(0,str(HERE.parents[1]))
from test_quant import model
from test_dct import transform
from integration.tooling import execute
r=random.Random(391);data=[r.randint(-100,100) for _ in range(64)];table=[1+i//8+i%8 for i in range(64)]
coeff=transform(data);quant,_=model(coeff,table,False,16);dequant,_=model(quant,table,True,16);expected=transform(dequant,True)
with tempfile.TemporaryDirectory(prefix='jpeg_pipeline_') as td:
 p=Path(td)
 for name,values in [('in.mem',data),('out.mem',expected),('table.mem',table)]:
  (p/name).write_text('\n'.join(f'{x&65535:x}' for x in values))
 tb='''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,cv=0,tv=0,sv=0,mr=1;reg [5:0] ti;reg [7:0] tq;reg signed [15:0] sd;
 wire r0,v0,r1,v1,r2,v2,r3,v3;wire signed [15:0] d0,d1,d2,d3;wire c0,c1,c2,c3,done1,done2,e1,e2;
 dct8x8_serial f(clk,rst,1'b1,1'b0,1'b0,c0,,sd,sv,r0,d0,v0,r1,,);
 jpeg_quant_zigzag q(clk,rst,1'b1,tv,,ti,tq,cv,1'b0,c1,done1,e1,d0,v0,r1,d1,v1,r2,,);
 jpeg_quant_zigzag dq(clk,rst,1'b1,tv,,ti,tq,cv,1'b1,c2,done2,e2,d1,v1,r2,d2,v2,r3,,);
 dct8x8_serial inv(clk,rst,1'b1,cv,1'b1,c3,,d2,v2,r3,d3,v3,mr,,);
 reg [15:0] im[0:63],om[0:63];reg [7:0] tm[0:63];integer i,ii=0,oo=0,ticks=0;
 always @(posedge clk) begin
 ticks=ticks+1;if(ticks>20000) $fatal(1,"timeout");
 if(rst&&sv&&r0) ii=ii+1;
 if(rst&&v3&&mr) begin if(d3!==om[oo]) $fatal(1,"pipeline pixel=%0d got=%0d exp=%0d",oo,d3,$signed(om[oo]));oo=oo+1;end
 end
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);$readmemh("table.mem",tm);
 repeat(3) @(negedge clk);rst=1;
 for(i=0;i<64;i=i+1) begin tv=1;ti=i;tq=tm[i];@(negedge clk);end tv=0;
 cv=1;@(negedge clk);cv=0;wait(done1&&done2);@(negedge clk);if(e1||e2) $fatal(1,"config");
 while(ii<64) begin sd=im[ii];sv=1;@(negedge clk);end sv=0;
 wait(oo==64);@(negedge clk);$display("PASS actual DCT->quant->dequant->IDCT 64 numerical pixels");$finish;
 end endmodule'''
 (p/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'jpeg_quant_zigzag.sv',HERE.parent/'dct8x8/dct8x8_serial.sv',p/'tb.sv'],p,p/'compile.log')
 text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS actual' in text;print(text.strip())
 (HERE/'pipeline_evidence.json').write_text(json.dumps({'result':'PASS','pixels':64,'max_lossy_reconstruction_error':max(abs(a-b) for a,b in zip(data,expected)),'pipeline':['DCT','quant+zigzag','inversezigzag+dequant','IDCT']},indent=2)+'\n')
